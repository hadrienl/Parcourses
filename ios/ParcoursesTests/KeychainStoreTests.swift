import Foundation
import Security
import Testing

@testable import Parcourses

@Suite(.serialized)
struct KeychainStoreTests {
  private let store = KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")

  @Test func storesReplacesAndRemoves() throws {
    #expect(try store.data(forKey: "k") == nil)
    try store.set(Data("a".utf8), forKey: "k")
    try store.set(Data("b".utf8), forKey: "k")
    #expect(try store.data(forKey: "k") == Data("b".utf8))
    try store.removeValue(forKey: "k")
    #expect(try store.data(forKey: "k") == nil)
    try store.removeValue(forKey: "k")
  }

  @Test func usesTheDeviceOnlyAfterFirstUnlockClass() throws {
    try store.set(Data("a".utf8), forKey: "k")
    defer { try? store.removeAll() }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: store.service,
      kSecAttrAccount as String: "k",
      kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
    let attributes = try #require(result as? [String: Any])
    #expect(
      attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }

  @Test func firstLaunchWipesThenKeeps() throws {
    let suite = "app.parcourses.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try store.set(Data("old".utf8), forKey: "session")
    AuthBootstrap.resetAfterReinstall(defaults: defaults, keychain: store)
    #expect(try store.data(forKey: "session") == nil)

    try store.set(Data("new".utf8), forKey: "session")
    AuthBootstrap.resetAfterReinstall(defaults: defaults, keychain: store)
    #expect(try store.data(forKey: "session") == Data("new".utf8))
    try store.removeAll()
  }
}

/// Keychain verrouillé, comme en arrière-plan avant le premier déverrouillage.
private nonisolated struct LockedStore: SecureStore {
  func data(forKey key: String) throws -> Data? { throw KeychainError(status: errSecInteractionNotAllowed) }
  func set(_ data: Data, forKey key: String) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
  func removeValue(forKey key: String) throws { throw KeychainError(status: errSecInteractionNotAllowed) }
  func removeAll() throws { throw KeychainError(status: errSecInteractionNotAllowed) }
}

struct LockedKeychainTests {
  @Test func noAnonymousSignInWhileTheKeychainIsLocked() async throws {
    #expect(errSecInteractionNotAllowed == -25308)
    // Adresse injoignable : une tentative de connexion donnerait `.network`, pas `.unauthorized`.
    let configuration = try #require(SupabaseConfiguration(url: "http://127.0.0.1:9", publishableKey: "k"))
    let gateway = SupabaseGateway(configuration: configuration, store: LockedStore())
    await #expect(throws: RemoteError.unauthorized) { try await gateway.ensureSession() }
  }

  @Test func sentinelRoundTripsOnARealKeychain() throws {
    let store = KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")
    try store.verifyAvailable()
    try store.removeAll()
  }
}
