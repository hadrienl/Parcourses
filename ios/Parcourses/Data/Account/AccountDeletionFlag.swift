import Foundation

/// Où en est une suppression de compte (#68 §5.3). Mêmes valeurs sur Android.
nonisolated enum AccountDeletionPhase: String, Codable, Sendable {
  /// Demandée : le serveur n'a pas encore confirmé la suppression.
  case requested
  /// Confirmée par le serveur : il ne reste que la purge de l'appareil.
  case serverDeleted
}

/// Drapeau durable `account.deletion`. Tant qu'il existe, ni synchronisation ni `ensureSession` : un compte créé
/// avant la purge recevrait toutes les données par `AccountRekey`. Effacé en dernier, après la purge.
nonisolated struct AccountDeletionFlag: Codable, Equatable, Sendable {
  static let key = "account.deletion"

  /// Compte à supprimer, `nil` s'il n'y avait pas de session (rien à supprimer côté serveur).
  var accountId: UUID?
  var phase: AccountDeletionPhase
}

/// Lecture et écriture du drapeau, injectables dans les tests.
nonisolated protocol AccountDeletionFlagStore: Sendable {
  func load() -> AccountDeletionFlag?
  func save(_ flag: AccountDeletionFlag)
  func clear()
}

nonisolated extension AccountDeletionFlagStore {
  var isDeletionPending: Bool { load() != nil }
}

/// Dans `UserDefaults.standard`, à côté des curseurs : rien de secret, et lisible avant le premier déverrouillage.
nonisolated struct UserDefaultsAccountDeletionFlagStore: AccountDeletionFlagStore, @unchecked Sendable {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Un drapeau illisible (écrit par une version future) compte comme présent : mieux vaut purger deux fois que
  /// laisser un nouveau compte reprendre les données.
  func load() -> AccountDeletionFlag? {
    guard let data = defaults.data(forKey: AccountDeletionFlag.key) else { return nil }
    return (try? JSONDecoder().decode(AccountDeletionFlag.self, from: data))
      ?? AccountDeletionFlag(accountId: nil, phase: .requested)
  }

  func save(_ flag: AccountDeletionFlag) {
    // L'encodage d'une structure de deux champs ne peut pas échouer.
    let data = (try? JSONEncoder().encode(flag)) ?? Data()
    defaults.set(data, forKey: AccountDeletionFlag.key)
  }

  func clear() {
    defaults.removeObject(forKey: AccountDeletionFlag.key)
  }
}
