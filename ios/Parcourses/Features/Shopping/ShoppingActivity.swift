import ActivityKit
import Foundation

extension ShoppingActivityAttributes.ContentState {
  /// État de la Live Activity à partir des lignes du mode courses. Une ligne juste cochée reste dans `toBuy` le
  /// temps du tri : elle compte comme prise, et le prochain article est le premier qui ne l'est pas.
  static func make(
    toBuy: [ShoppingRow], basket: [ShoppingRow], categoryLabel: (String) -> String?, isFinished: Bool = false
  ) -> Self {
    let pending = toBuy.filter { !$0.isChecked }
    let next = pending.first
    return Self(
      remaining: pending.count, total: toBuy.count + basket.count,
      nextItemLabel: next?.label, nextCategoryLabel: next.flatMap { categoryLabel($0.aisleId) },
      isFinished: isFinished)
  }
}

/// Pilote de la Live Activity. Découplé d'ActivityKit pour que les tests vérifient les mises à jour.
@MainActor
protocol ShoppingActivityControlling: AnyObject {
  func start(attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState)
  func update(state: ShoppingActivityAttributes.ContentState)
  /// Affiche l'état final puis retire l'activité.
  func end(state: ShoppingActivityAttributes.ContentState)
}

/// Implémentation ActivityKit. Les appels système sont asynchrones : une chaîne de tâches garde leur ordre.
/// L'`Activity` n'est pas `Sendable` : on n'en garde que l'identifiant, et chaque appel la retrouve sur place.
@MainActor
final class ActivityKitShoppingActivity: ShoppingActivityControlling {
  /// Le dernier état reste à l'écran de verrouillage ce temps après la fin de la visite.
  static let dismissalDelay: TimeInterval = 5 * 60

  private var activityId: String?
  private var chain: Task<Void, Never>?

  func start(attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState) {
    enqueue { [self] _ in
      activityId = await Self.request(attributes: attributes, state: state)
    }
  }

  func update(state: ShoppingActivityAttributes.ContentState) {
    enqueue { [self] _ in
      guard let id = activityId else { return }
      await Self.update(id: id, state: state)
    }
  }

  func end(state: ShoppingActivityAttributes.ContentState) {
    enqueue { [self] _ in
      guard let id = activityId else { return }
      await Self.end(id: id, state: state)
      activityId = nil
    }
  }

  private func enqueue(_ work: @escaping @MainActor (String?) async -> Void) {
    let previous = chain
    chain = Task {
      await previous?.value
      await work(activityId)
    }
  }

  /// Reprend l'activité restée d'un lancement précédent (reprise de visite) en retirant les autres, sinon en crée une.
  private nonisolated static func request(
    attributes: ShoppingActivityAttributes, state: ShoppingActivityAttributes.ContentState
  ) async -> String? {
    let content = ActivityContent(state: state, staleDate: nil)
    let existing = Activity<ShoppingActivityAttributes>.activities
    for extra in existing.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
    if let first = existing.first {
      await first.update(content)
      return first.id
    }
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return nil }
    // Refus possible (activités désactivées, trop d'activités) : la visite se passe très bien sans.
    return (try? Activity.request(attributes: attributes, content: content, pushType: nil))?.id
  }

  private nonisolated static func update(id: String, state: ShoppingActivityAttributes.ContentState) async {
    let activity = Activity<ShoppingActivityAttributes>.activities.first { $0.id == id }
    await activity?.update(ActivityContent(state: state, staleDate: nil))
  }

  private nonisolated static func end(id: String, state: ShoppingActivityAttributes.ContentState) async {
    let activity = Activity<ShoppingActivityAttributes>.activities.first { $0.id == id }
    await activity?.end(
      ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + dismissalDelay))
  }
}
