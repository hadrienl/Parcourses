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

  /// Compte à supprimer, `nil` s'il n'y avait pas de session. À la reprise, une session absente ou d'un autre compte
  /// ne permet plus d'atteindre ce compte : l'appareil seul est purgé.
  var accountId: UUID?
  var phase: AccountDeletionPhase
  /// La RPC a été envoyée au moins une fois : un refus ou un envoi impossible ne prouvent plus que rien n'a été
  /// supprimé, seul `confirmAccountDeleted` permet alors d'abandonner.
  var rpcAttempted: Bool

  init(accountId: UUID?, phase: AccountDeletionPhase, rpcAttempted: Bool = false) {
    self.accountId = accountId
    self.phase = phase
    self.rpcAttempted = rpcAttempted
  }

  private enum CodingKeys: String, CodingKey {
    case accountId, phase, rpcAttempted
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountId = try container.decodeIfPresent(UUID.self, forKey: .accountId)
    phase = try container.decode(AccountDeletionPhase.self, forKey: .phase)
    // Absent : traité comme envoyé, la prudence l'emporte.
    rpcAttempted = try container.decodeIfPresent(Bool.self, forKey: .rpcAttempted) ?? true
  }
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

/// Dans `UserDefaults.standard`, à côté des curseurs : rien de secret. Comme eux, il n'est lisible qu'après le premier
/// déverrouillage ; avant, la session (Keychain) et le store ne le sont pas non plus, donc aucune passe n'aboutit.
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
      ?? AccountDeletionFlag(accountId: nil, phase: .requested, rpcAttempted: true)
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
