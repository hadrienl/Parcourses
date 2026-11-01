import Foundation
import Security

/// Erreur renvoyée par les services de trousseau.
nonisolated struct KeychainError: Error, Equatable {
  let status: OSStatus
}

/// Stockage sécurisé injectable : les tests simulent un Keychain verrouillé (`errSecInteractionNotAllowed`).
nonisolated protocol SecureStore: Sendable {
  func data(forKey key: String) throws -> Data?
  func set(_ data: Data, forKey key: String) throws
  func removeValue(forKey key: String) throws
  func removeAll() throws
}

nonisolated extension SecureStore {
  /// Écrit puis relit une sentinelle de même accessibilité que la session : une simple lecture ne suffit
  /// pas à prouver qu'une session pourra être persistée.
  func verifyAvailable() throws {
    let sentinel = Data(UUID().uuidString.utf8)
    try set(sentinel, forKey: "availability-sentinel")
    guard try data(forKey: "availability-sentinel") == sentinel else {
      throw KeychainError(status: errSecDataNotAvailable)
    }
  }
}

/// Petit magasin clé/valeur adossé au Keychain (éléments `kSecClassGenericPassword`).
///
/// `AfterFirstUnlockThisDeviceOnly` : le jeton reste lisible en arrière-plan après le premier
/// déverrouillage (`BGAppRefreshTask`) et ne quitte jamais l'appareil.
nonisolated struct KeychainStore: SecureStore {
  static let authService = "app.parcourses.auth"

  let service: String

  init(service: String = KeychainStore.authService) {
    self.service = service
  }

  func data(forKey key: String) throws(KeychainError) -> Data? {
    var query = baseQuery(forKey: key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return result as? Data
    case errSecItemNotFound: return nil
    default: throw KeychainError(status: status)
    }
  }

  func set(_ data: Data, forKey key: String) throws(KeychainError) {
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let query = baseQuery(forKey: key)
    let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }
    let added = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(status: added) }
  }

  func removeValue(forKey key: String) throws(KeychainError) {
    try delete(baseQuery(forKey: key))
  }

  /// Efface tous les éléments du service.
  func removeAll() throws(KeychainError) {
    try delete([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
    ])
  }

  private func delete(_ query: [String: Any]) throws(KeychainError) {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func baseQuery(forKey key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }
}
