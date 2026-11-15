import Foundation

/// Une opération de compte à la fois (#87) : la vérification d'un code et sa reprise, le rejeu de `account.switch`,
/// la déconnexion, « Réessayer » et « Continuer sans compte ». Sans elle, la purge d'un rejeu pourrait passer au milieu
/// d'une vérification et effacer le compte qui vient d'être ouvert. Le rejeu de `account.signOut` n'y passe pas : il
/// reste synchrone dans `AppModel.init`, avant tout écran, quand aucune vérification ne peut être en cours.
///
/// Les opérations s'enchaînent dans l'ordre d'arrivée. Une opération ne doit jamais en attendre une autre de la même
/// file : elle s'attendrait elle-même.
final class AccountOperationQueue {
  private var tail: Task<Void, Never>?

  /// Lance `operation` après celles déjà en file, et attend son résultat.
  func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
    let previous = tail
    let work = Task { @MainActor in
      await previous?.value
      return await operation()
    }
    tail = Task { _ = await work.value }
    return await work.value
  }
}
