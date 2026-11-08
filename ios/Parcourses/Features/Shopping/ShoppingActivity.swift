import ActivityKit
import Foundation
import os

extension ShoppingActivityAttributes.ContentState {
  /// ActivityKit plafonne l'état à 4 Ko : un libellé démesuré ferait refuser la mise à jour.
  static let maxLabelLength = 60

  /// État de la Live Activity à partir des lignes du mode courses. Une ligne juste cochée reste dans `toBuy` le
  /// temps du tri : elle compte comme prise, et le prochain article est le premier qui ne l'est pas.
  static func make(
    toBuy: [ShoppingRow], basket: [ShoppingRow], categoryLabel: (String) -> String?, isFinished: Bool = false
  ) -> Self {
    let pending = toBuy.filter { !$0.isChecked }
    let next = pending.first
    return Self(
      remaining: pending.count, total: toBuy.count + basket.count,
      nextItemLabel: next.map { String($0.label.prefix(maxLabelLength)) },
      nextCategoryLabel: next.flatMap { categoryLabel($0.aisleId) }.map { String($0.prefix(maxLabelLength)) },
      isFinished: isFinished)
  }
}

/// Activité vue par ActivityKit, réduite à ce qu'il faut pour décider de la reprise.
nonisolated struct ActivityInfo: Equatable, Sendable {
  let id: String
  let visitId: UUID?
  /// Active ou simplement périmée (`.stale`) ; ni terminée ni en attente de disparition.
  let isActive: Bool
}

nonisolated enum ActivityEndPolicy: Equatable, Sendable {
  case immediate
  case after(Date)
}

/// Accès à ActivityKit, isolé pour tester la reprise et le nettoyage sans le framework.
nonisolated protocol ActivityBackend: Sendable {
  func current() async -> [ActivityInfo]
  /// Identifiant de l'activité créée, `nil` si le système refuse.
  func request(
    attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState, staleDate: Date?
  ) async -> String?
  func update(id: String, state: ShoppingActivityAttributes.ContentState, staleDate: Date?) async
  func end(id: String, state: ShoppingActivityAttributes.ContentState?, policy: ActivityEndPolicy) async
}

/// ActivityKit réel. L'`Activity` n'est pas `Sendable` : on la retrouve par identifiant à chaque appel.
nonisolated struct ActivityKitBackend: ActivityBackend {
  private static let log = Logger(subsystem: "app.parcourses", category: "LiveActivity")

  func current() async -> [ActivityInfo] {
    Activity<ShoppingActivityAttributes>.activities.map {
      ActivityInfo(
        id: $0.id, visitId: $0.attributes.visitId, isActive: $0.activityState == .active || $0.activityState == .stale)
    }
  }

  func request(
    attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState, staleDate: Date?
  ) async -> String? {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      Self.log.info("Live Activity refusée : activités désactivées")
      return nil
    }
    do {
      return try Activity.request(
        attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate), pushType: nil
      ).id
    } catch {
      // La visite se passe très bien sans : on trace, et on retentera au retour au premier plan.
      Self.log.error("Live Activity non démarrée : \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  func update(id: String, state: ShoppingActivityAttributes.ContentState, staleDate: Date?) async {
    guard let activity = Activity<ShoppingActivityAttributes>.activities.first(where: { $0.id == id }) else {
      Self.log.error("Live Activity introuvable pour la mise à jour")
      return
    }
    await activity.update(ActivityContent(state: state, staleDate: staleDate))
  }

  func end(id: String, state: ShoppingActivityAttributes.ContentState?, policy: ActivityEndPolicy) async {
    guard let activity = Activity<ShoppingActivityAttributes>.activities.first(where: { $0.id == id }) else {
      return
    }
    let dismissal: ActivityUIDismissalPolicy
    switch policy {
    case .immediate: dismissal = .immediate
    case .after(let date): dismissal = .after(date)
    }
    await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: dismissal)
  }
}

/// Pilote de la Live Activity. Découplé d'ActivityKit pour que les tests vérifient les mises à jour.
@MainActor
protocol ShoppingActivityControlling: AnyObject {
  func start(attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState)
  func update(state: ShoppingActivityAttributes.ContentState)
  /// Affiche l'état final puis retire l'activité, même si elle vient d'un lancement précédent.
  func end(state: ShoppingActivityAttributes.ContentState)
  /// Retente un démarrage refusé ou perdu (retour au premier plan).
  func retryIfNeeded()
  /// Termine tout de suite les activités qui ne suivent pas cette visite (orphelines d'un lancement précédent).
  func endAll(except visitId: UUID?)
}

/// Instance unique, partagée par toutes les sessions : les appels système sont asynchrones, une chaîne de tâches
/// garde leur ordre.
@MainActor
final class ActivityKitShoppingActivity: ShoppingActivityControlling {
  /// Le dernier état reste à l'écran de verrouillage ce temps après la fin de la visite.
  static let dismissalDelay: TimeInterval = 5 * 60

  private let backend: any ActivityBackend
  private let now: () -> Date
  private var activityId: String?
  private var attributes: ShoppingActivityAttributes?
  private var lastState: ShoppingActivityAttributes.ContentState?
  private var chain: Task<Void, Never>?

  init(backend: any ActivityBackend = ActivityKitBackend(), now: @escaping () -> Date = { .now }) {
    self.backend = backend
    self.now = now
  }

  /// Attend les appels en cours : pour les tests.
  func waitUntilIdle() async {
    await chain?.value
  }

  /// Sans coche pendant la durée d'expiration d'une visite, l'activité devient « inactive » d'elle-même, sans que
  /// l'app ait à tourner.
  private var staleDate: Date { now().addingTimeInterval(ShoppingSession.expiry) }

  func start(attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState) {
    self.attributes = attributes
    lastState = state
    activityId = nil
    enqueue { await self.open() }
  }

  func update(state: ShoppingActivityAttributes.ContentState) {
    lastState = state
    enqueue {
      guard self.attributes != nil else { return }
      if let id = self.activityId {
        await self.backend.update(id: id, state: state, staleDate: self.staleDate)
      } else {
        await self.open()
      }
    }
  }

  func end(state: ShoppingActivityAttributes.ContentState) {
    attributes = nil
    lastState = nil
    enqueue {
      let ids: [String]
      if let id = self.activityId {
        ids = [id]
      } else {
        ids = await self.backend.current().filter(\.isActive).map(\.id)
      }
      for id in ids {
        await self.backend.end(id: id, state: state, policy: .after(self.now().addingTimeInterval(Self.dismissalDelay)))
      }
      self.activityId = nil
    }
  }

  func retryIfNeeded() {
    enqueue {
      guard self.attributes != nil, self.activityId == nil else { return }
      await self.open()
    }
  }

  func endAll(except visitId: UUID?) {
    enqueue {
      for info in await self.backend.current() where visitId == nil || info.visitId != visitId {
        await self.backend.end(id: info.id, state: nil, policy: .immediate)
        if info.id == self.activityId { self.activityId = nil }
      }
    }
  }

  /// Reprend l'activité active de la même visite ; toute autre (autre visite, terminée) est retirée, puis on en
  /// crée une neuve. Les attributs d'une activité sont immuables : reprendre n'importe laquelle afficherait
  /// la mauvaise liste.
  private func open() async {
    guard let attributes, let state = lastState else { return }
    let existing = await backend.current()
    let reusable = existing.first { $0.isActive && attributes.visitId != nil && $0.visitId == attributes.visitId }
    for info in existing where info.id != reusable?.id {
      await backend.end(id: info.id, state: nil, policy: .immediate)
    }
    if let reusable {
      await backend.update(id: reusable.id, state: state, staleDate: staleDate)
      activityId = reusable.id
    } else {
      activityId = await backend.request(attributes: attributes, state: state, staleDate: staleDate)
    }
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) {
    let previous = chain
    chain = Task {
      await previous?.value
      await work()
    }
  }
}
