import Foundation
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
