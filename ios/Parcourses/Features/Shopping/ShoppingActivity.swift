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
      nextAisleId: next?.aisleId, isFinished: isFinished,
      pendingItemIds: isFinished ? [] : pending.prefix(maxPendingItems).map(\.id))
  }

  /// Confronte l'état affiché à la base, sans mode courses ouvert (« Cocher le suivant », app tuée) : un article
  /// coché ailleurs, introuvable ou supprimé quitte la file, l'ordre affiché ne change pas (seul le mode courses
  /// recalcule le tri, comme `ShoppingLiveState.reconciled` d'Android). Les articles à prendre hors de la file
  /// (au-delà de `maxPendingItems`, ajoutés, décochés) la suivent, dans l'ordre de la liste. `items` : les
  /// articles de la liste, dans l'ordre de `position` ; `describe` : libellé, rayon effectif et titre du rayon
  /// affichés d'un article.
  func reconciled(
    items: [ListItem], describe: (ListItem) -> (label: String, aisleId: String, aisle: String?)
  ) -> Self {
    let pending = items.filter { $0.checkedAt == nil && $0.notFoundAt == nil }
    let pendingIds = Set(pending.map(\.id))
    let kept = pendingItemIds.filter { pendingIds.contains($0) }
    let keptIds = Set(kept)
    let order = kept + pending.map(\.id).filter { !keptIds.contains($0) }
    let next = order.first.flatMap { id in items.first { $0.id == id } }.map(describe)
    return Self(
      remaining: pending.count, total: items.filter { $0.checkedAt != nil || $0.notFoundAt == nil }.count,
      nextItemLabel: next.map { String($0.label.prefix(Self.maxLabelLength)) },
      nextCategoryLabel: next?.aisle.map { String($0.prefix(Self.maxLabelLength)) }, nextAisleId: next?.aisleId,
      isFinished: false, pendingItemIds: Array(order.prefix(Self.maxPendingItems)))
  }
}

/// Activité vue par ActivityKit, réduite à ce qu'il faut pour décider de la reprise.
nonisolated struct ActivityInfo: Equatable, Sendable {
  let id: String
  let visitId: UUID?
  /// Active ou simplement périmée (`.stale`) ; ni terminée ni en attente de disparition.
  let isActive: Bool
  /// Ce qu'elle affiche : l'app relancée par « Cocher le suivant » repart de là.
  var attributes: ShoppingActivityAttributes?
  var state: ShoppingActivityAttributes.ContentState?
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
  /// `false` si l'activité n'est plus affichée : écartée par la personne, ou retirée par le système.
  @discardableResult
  func update(id: String, state: ShoppingActivityAttributes.ContentState, staleDate: Date?) async -> Bool
  func end(id: String, state: ShoppingActivityAttributes.ContentState?, policy: ActivityEndPolicy) async
}

/// Visites dont la personne a écarté la Live Activity : elle ne revient pas pour elles, même après une relance
/// (comme la notification écartée d'Android, #52).
nonisolated protocol ActivityDismissals: Sendable {
  func contains(_ visitId: UUID) -> Bool
  func remember(_ visitId: UUID)
}

/// Retenue dans les préférences de l'app : une seule visite est en cours à la fois, la dernière suffit.
nonisolated struct UserDefaultsActivityDismissals: ActivityDismissals {
  private static let key = "liveActivityDismissedVisitId"

  func contains(_ visitId: UUID) -> Bool {
    UserDefaults.standard.string(forKey: Self.key) == visitId.uuidString
  }

  func remember(_ visitId: UUID) {
    UserDefaults.standard.set(visitId.uuidString, forKey: Self.key)
  }
}

/// ActivityKit réel. L'`Activity` n'est pas `Sendable` : on la retrouve par identifiant à chaque appel.
nonisolated struct ActivityKitBackend: ActivityBackend {
  private static let log = Logger(subsystem: "app.parcourses", category: "LiveActivity")

  func current() async -> [ActivityInfo] {
    Activity<ShoppingActivityAttributes>.activities.map {
      ActivityInfo(
        id: $0.id, visitId: $0.attributes.visitId, isActive: $0.activityState == .active || $0.activityState == .stale,
        attributes: $0.attributes, state: $0.content.state)
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

  func update(id: String, state: ShoppingActivityAttributes.ContentState, staleDate: Date?) async -> Bool {
    guard let activity = Activity<ShoppingActivityAttributes>.activities.first(where: { $0.id == id }),
      activity.activityState == .active || activity.activityState == .stale
    else {
      // Cas normal : la personne l'a écartée de l'écran verrouillé. Rien d'anormal à journaliser en erreur.
      Self.log.info("Live Activity écartée : plus de mise à jour pour cette visite")
      return false
    }
    await activity.update(ActivityContent(state: state, staleDate: staleDate))
    return true
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
  /// `lastActivity` : dernière coche de la visite, sinon son début. L'activité devient « inactive » 45 min après,
  /// quand la visite expire, même si l'app ne tourne plus (#52).
  func start(
    attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState, lastActivity: Date)
  func update(state: ShoppingActivityAttributes.ContentState, lastActivity: Date)
  /// Affiche l'état final puis retire l'activité, même si elle vient d'un lancement précédent.
  func end(state: ShoppingActivityAttributes.ContentState)
  /// Retente un démarrage refusé (retour au premier plan). Une activité écartée par la personne ne revient pas.
  func retryIfNeeded()
  /// Termine tout de suite les activités en cours qui ne suivent pas cette visite (orphelines d'un lancement
  /// précédent). Le message « Courses terminées » d'une visite finie reste affiché jusqu'à son retrait prévu.
  func endAll(except visitId: UUID?)
  /// État affiché pour cette visite. App relancée, l'activité active laissée par le lancement précédent est
  /// reprise (identifiant, attributs, état) : les mises à jour suivantes lui parviennent. `nil` si rien ne la suit.
  func restore(visitId: UUID) async -> ShoppingActivityAttributes.ContentState?
  /// Attend les appels système en cours (fin de « Cocher le suivant », avant que l'app soit suspendue).
  func waitUntilIdle() async
}

/// Instance unique, partagée par toutes les sessions : les appels système sont asynchrones, une chaîne de tâches
/// garde leur ordre.
@MainActor
final class ActivityKitShoppingActivity: ShoppingActivityControlling {
  /// Le dernier état reste à l'écran de verrouillage ce temps après la fin de la visite.
  static let dismissalDelay: TimeInterval = 5 * 60

  private let backend: any ActivityBackend
  private let dismissals: any ActivityDismissals
  private let now: () -> Date
  private var activityId: String?
  private var attributes: ShoppingActivityAttributes?
  private var lastState: ShoppingActivityAttributes.ContentState?
  private var lastActivity = Date.distantPast
  /// Démarrage refusé (activités désactivées, app en arrière-plan) : seul le retour au premier plan le retente,
  /// pas chaque mise à jour.
  private var isWaitingForForeground = false
  /// La personne a écarté l'activité de cette visite : plus rien ne la rouvre.
  private var isDismissed = false
  private var chain: Task<Void, Never>?

  init(
    backend: any ActivityBackend = ActivityKitBackend(),
    dismissals: any ActivityDismissals = UserDefaultsActivityDismissals(), now: @escaping () -> Date = { .now }
  ) {
    self.backend = backend
    self.dismissals = dismissals
    self.now = now
  }

  /// Attend les appels en cours : pour les tests.
  func waitUntilIdle() async {
    await chain?.value
  }

  /// Sans coche pendant la durée d'expiration d'une visite, l'activité devient « inactive » d'elle-même, sans que
  /// l'app ait à tourner. Calée sur la dernière coche, comme l'expiration de la visite et la Live Update Android :
  /// un retour au premier plan ne la repousse pas.
  private var staleDate: Date { lastActivity.addingTimeInterval(ShoppingSession.expiry) }

  func start(
    attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState, lastActivity: Date
  ) {
    self.attributes = attributes
    lastState = state
    self.lastActivity = lastActivity
    activityId = nil
    isWaitingForForeground = false
    isDismissed = attributes.visitId.map { dismissals.contains($0) } ?? false
    let stale = staleDate
    enqueue { await self.open(staleDate: stale) }
  }

  func update(state: ShoppingActivityAttributes.ContentState, lastActivity: Date) {
    lastState = state
    self.lastActivity = lastActivity
    // Calculée à l'appel : la chaîne s'exécute plus tard, quand une coche suivante a pu la changer.
    let stale = staleDate
    enqueue {
      guard self.attributes != nil, !self.isDismissed else { return }
      if let id = self.activityId {
        if !(await self.backend.update(id: id, state: state, staleDate: stale)) { self.dismiss() }
      } else if !self.isWaitingForForeground {
        await self.open(staleDate: stale)
      }
    }
  }

  /// L'activité suivie a disparu sans que l'app la termine : la personne l'a écartée. Le geste est respecté
  /// jusqu'à la fin de la visite, relance comprise.
  private func dismiss() {
    activityId = nil
    isDismissed = true
    if let visitId = attributes?.visitId { dismissals.remember(visitId) }
  }

  func restore(visitId: UUID) async -> ShoppingActivityAttributes.ContentState? {
    let previous = chain
    let task = Task { () -> ShoppingActivityAttributes.ContentState? in
      await previous?.value
      if let attributes = self.attributes {
        // Une session suit déjà une visite : seule la sienne est reconnue.
        return attributes.visitId == visitId ? self.lastState : nil
      }
      guard
        let info = await self.backend.current().first(where: { $0.isActive && $0.visitId == visitId }),
        let attributes = info.attributes, let state = info.state, !state.isFinished
      else { return nil }
      self.attributes = attributes
      self.lastState = state
      self.activityId = info.id
      // Inconnue ici : la mise à jour suivante la fournit, seule source de la `staleDate`.
      self.lastActivity = .distantPast
      return state
    }
    // Les appels suivants attendent la reprise : ils doivent voir l'activité retrouvée.
    chain = Task { _ = await task.value }
    return await task.value
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
      guard self.attributes != nil, self.activityId == nil, !self.isDismissed else { return }
      self.isWaitingForForeground = false
      await self.open(staleDate: self.staleDate)
    }
  }

  func endAll(except visitId: UUID?) {
    enqueue {
      // Une activité déjà terminée affiche « Courses terminées » jusqu'à son retrait prévu : on la laisse.
      for info in await self.backend.current() where info.isActive && (visitId == nil || info.visitId != visitId) {
        await self.backend.end(id: info.id, state: nil, policy: .immediate)
        if info.id == self.activityId {
          // L'activité suivie est retirée : rien ne doit la rouvrir (retour au premier plan) avec un état ancien.
          self.activityId = nil
          self.attributes = nil
          self.lastState = nil
        }
      }
    }
  }

  /// Reprend l'activité active de la même visite, sinon en crée une neuve ; toute autre (autre visite, terminée)
  /// est ensuite retirée. Les attributs d'une activité sont immuables : reprendre n'importe laquelle afficherait
  /// la mauvaise liste. La neuve est demandée avant le retrait des autres : après une reprise de compte, elle
  /// remplace l'ancienne sans que l'écran verrouillé reste un instant vide.
  private func open(staleDate: Date) async {
    guard let attributes, let state = lastState, !isDismissed else { return }
    let existing = await backend.current()
    let reusable = existing.first { $0.isActive && attributes.visitId != nil && $0.visitId == attributes.visitId }
    if let reusable {
      await backend.update(id: reusable.id, state: state, staleDate: staleDate)
      activityId = reusable.id
    } else if let id = await backend.request(attributes: attributes, state: state, staleDate: staleDate) {
      activityId = id
    } else {
      isWaitingForForeground = true
    }
    for info in existing where info.id != reusable?.id {
      await backend.end(id: info.id, state: nil, policy: .immediate)
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
