import Foundation

/// Nature du compte de l'appareil (#87 §2.4). Mêmes valeurs sur Android.
nonisolated enum AccountKind: String, Codable, Sendable {
  case anonymous
  case email
}

/// Drapeau durable `account.kind`. Une session perdue d'un compte e-mail ne doit jamais faire naître un compte
/// anonyme en silence (vecteur `009`) : le drapeau survit à la perte du Keychain. Effacé par `LocalDataPurge`.
nonisolated protocol AccountKindStore: Sendable {
  var kind: AccountKind { get }
  func save(_ kind: AccountKind)
}

/// Dans `UserDefaults.standard`, à côté des curseurs et de `account.deletion` : rien de secret.
nonisolated struct UserDefaultsAccountKindStore: AccountKindStore, @unchecked Sendable {
  static let key = "account.kind"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Absent : compte anonyme, comme avant 87.3. Une valeur inconnue (version future) compte comme un compte e-mail :
  /// mieux vaut attendre une reconnexion que créer un compte de trop.
  var kind: AccountKind {
    guard let raw = defaults.string(forKey: Self.key) else { return .anonymous }
    return AccountKind(rawValue: raw) ?? .email
  }

  func save(_ kind: AccountKind) {
    defaults.set(kind.rawValue, forKey: Self.key)
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
  }
}
