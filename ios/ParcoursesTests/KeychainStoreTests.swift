import Foundation
import Security
import Synchronization
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
    let keychain = GuardedSecureStore(base: store, defaults: defaults, monitor: KeyAccessMonitor())

    try store.set(Data("old".utf8), forKey: "session")
    AuthBootstrap.resetAfterReinstall(keychain: keychain)
    #expect(try store.data(forKey: "session") == nil)
    #expect(defaults.bool(forKey: AuthBootstrap.installedFlag))

    try store.set(Data("new".utf8), forKey: "session")
    AuthBootstrap.resetAfterReinstall(keychain: keychain)
    #expect(try store.data(forKey: "session") == Data("new".utf8))
    #expect(try keychain.data(forKey: "session") == Data("new".utf8))
    try store.removeAll()
  }
}

/// Horloge monotone des tests, avancée à la main.
nonisolated final class TestMonotonicClock: Sendable {
  private let instant = Mutex(ContinuousClock.now)

  var now: ContinuousClock.Instant { instant.withLock { $0 } }

  func advance(by duration: Duration) {
    instant.withLock { $0 = $0.advanced(by: duration) }
  }
}

nonisolated extension KeyAccessMonitor {
  /// `stuckAfterFailures` échecs étalés sur `stuckAfter` : le Keychain devient bloqué.
  func recordFailuresUntilStuck(clock: TestMonotonicClock) {
    for index in 0..<Self.stuckAfterFailures {
      if index > 0 { clock.advance(by: Self.stuckAfter / (Self.stuckAfterFailures - 1)) }
      record(success: false)
    }
  }
}

/// Keychain « bloqué » (#133) : mêmes seuils qu'Android (`KeyAccessMonitor`).
struct KeyAccessMonitorTests {
  @Test func theThresholdsAreAndroidOnes() {
    #expect(KeyAccessMonitor.stuckAfterFailures == 3)
    #expect(KeyAccessMonitor.stuckAfter == .seconds(30))
  }

  @Test func threeFailuresSpreadOverThirtySecondsMakeItStuck() {
    let clock = TestMonotonicClock()
    let monitor = KeyAccessMonitor(now: { clock.now })
    monitor.record(success: false)
    clock.advance(by: .seconds(15))
    monitor.record(success: false)
    #expect(!monitor.isStuck)
    clock.advance(by: .seconds(15))
    monitor.record(success: false)
    #expect(monitor.isStuck)
  }

  /// Plusieurs appelants qui échouent ensemble pendant une panne passagère : pas assez. La série continue, et un échec
  /// au-delà des 30 s suffit.
  @Test func quickFailuresAreNotEnough() {
    let clock = TestMonotonicClock()
    let monitor = KeyAccessMonitor(now: { clock.now })
    for _ in 0..<5 { monitor.record(success: false) }
    clock.advance(by: .milliseconds(29_999))
    monitor.record(success: false)
    #expect(!monitor.isStuck)
    clock.advance(by: .milliseconds(1))
    monitor.record(success: false)
    #expect(monitor.isStuck)
  }

  @Test func oneSuccessResetsEverything() {
    let clock = TestMonotonicClock()
    let monitor = KeyAccessMonitor(now: { clock.now })
    monitor.recordFailuresUntilStuck(clock: clock)
    #expect(monitor.isStuck)
    monitor.record(success: true)
    #expect(!monitor.isStuck)
    // La série repart de zéro : deux échecs, même étalés, ne suffisent pas.
    monitor.record(success: false)
    clock.advance(by: .seconds(60))
    monitor.record(success: false)
    #expect(!monitor.isStuck)
    monitor.record(success: true)
    monitor.record(success: false)
    clock.advance(by: .seconds(60))
    monitor.record(success: false)
    #expect(!monitor.isStuck)
  }

  /// Appareil verrouillé (lancement en arrière-plan avant le premier déverrouillage) : les échecs ne comptent pas.
  @Test func failuresWithoutProtectedDataDoNotCount() {
    let clock = TestMonotonicClock()
    let availability = ProtectedDataAvailability(isAvailable: false)
    let monitor = KeyAccessMonitor(isProtectedDataAvailable: { availability.isAvailable }, now: { clock.now })
    for _ in 0..<3 {
      monitor.record(success: false)
      clock.advance(by: .seconds(30))
    }
    #expect(!monitor.isStuck)
    availability.update(true)
    monitor.record(success: false)
    monitor.record(success: false)
    #expect(!monitor.isStuck)
    clock.advance(by: .seconds(30))
    monitor.record(success: false)
    #expect(monitor.isStuck)
    // Verrouillé de nouveau : un échec n'efface pas le blocage, seul un succès le fait.
    availability.update(false)
    monitor.record(success: false)
    #expect(monitor.isStuck)
  }
}

/// Keychain de l'app (#133) : vidage en attente avant tout accès, purge sans lecture.
@Suite struct GuardedSecureStoreTests {
  private struct Fixture {
    let base = MemorySecureStore()
    let clock = TestMonotonicClock()
    let defaults: UserDefaults
    let store: GuardedSecureStore

    init(installed: Bool) throws {
      defaults = try #require(UserDefaults(suiteName: "tests.keychain.\(UUID().uuidString)"))
      if installed { defaults.set(true, forKey: AuthBootstrap.installedFlag) }
      let clock = self.clock
      store = GuardedSecureStore(base: base, defaults: defaults, monitor: KeyAccessMonitor(now: { clock.now }))
    }
  }

  private let refused = KeychainError(status: errSecInteractionNotAllowed)

  /// Réinstallation : rien n'est lu avant un vidage réussi, puis le drapeau est posé et les accès suivants ne vident
  /// plus.
  @Test func aPendingWipeComesBeforeAnyAccess() throws {
    let fixture = try Fixture(installed: false)
    try fixture.base.set(Data("old".utf8), forKey: "session")
    fixture.base.failsEverything = true
    fixture.base.forgetOperations()

    #expect(throws: refused) { try fixture.store.data(forKey: "session") }
    #expect(throws: refused) { try fixture.store.set(Data("new".utf8), forKey: "session") }
    #expect(throws: refused) { try fixture.store.removeValue(forKey: "session") }
    #expect(fixture.base.operations == ["removeAll", "removeAll", "removeAll"])
    #expect(fixture.store.isWipePending)

    fixture.base.failsEverything = false
    #expect(try fixture.store.data(forKey: "session") == nil)
    #expect(fixture.base.operations.suffix(2) == ["removeAll", "data:session"])
    #expect(fixture.defaults.bool(forKey: AuthBootstrap.installedFlag))
    #expect(!fixture.store.isWipePending)

    fixture.base.forgetOperations()
    try fixture.store.set(Data("new".utf8), forKey: "session")
    #expect(try fixture.store.data(forKey: "session") == Data("new".utf8))
    #expect(fixture.base.operations == ["set:session", "data:session"])
  }

  /// Premier essai au lancement : sans vidage dû, le Keychain n'est pas touché, et le suivi n'est pas remis à zéro.
  @Test func completingWithoutAPendingWipeTouchesNothing() throws {
    let fixture = try Fixture(installed: true)
    fixture.store.monitor.recordFailuresUntilStuck(clock: fixture.clock)
    try fixture.store.completePendingWipe()
    #expect(fixture.base.operations.isEmpty)
    #expect(fixture.store.monitor.isStuck)
  }

  /// Chaque accès est noté : un Keychain qui refuse tout devient bloqué, un accès réussi le débloque.
  @Test func everyAccessIsRecorded() throws {
    let fixture = try Fixture(installed: true)
    fixture.base.failsEverything = true
    #expect(throws: refused) { try fixture.store.data(forKey: "session") }
    fixture.clock.advance(by: .seconds(15))
    #expect(throws: refused) { try fixture.store.set(Data("x".utf8), forKey: "session") }
    fixture.clock.advance(by: .seconds(15))
    #expect(throws: refused) { try fixture.store.verifyAvailable() }
    #expect(fixture.store.monitor.isStuck)
    fixture.base.failsEverything = false
    #expect(try fixture.store.data(forKey: "session") == nil)
    #expect(!fixture.store.monitor.isStuck)
  }

  /// `clear` hors blocage : l'échec remonte, le drapeau reste.
  @Test func clearingThrowsWhileTheKeychainIsNotStuck() throws {
    let fixture = try Fixture(installed: true)
    fixture.base.failsRemoveAll = true
    #expect(throws: refused) { try fixture.store.clear() }
    fixture.clock.advance(by: .seconds(15))
    #expect(throws: refused) { try fixture.store.clear() }
    #expect(fixture.defaults.bool(forKey: AuthBootstrap.installedFlag))
    #expect(!fixture.store.monitor.isStuck)
  }

  /// `clear` réussi : Keychain vide, drapeau posé (un vidage en attente est fait du même coup).
  @Test func clearingEmptiesTheKeychain() throws {
    let fixture = try Fixture(installed: false)
    try fixture.base.set(Data("old".utf8), forKey: "session")
    try fixture.store.clear()
    #expect(fixture.base.keys.isEmpty)
    #expect(!fixture.store.isWipePending)
  }

  /// Keychain bloqué (cet échec compris) : `clear` réussit, le vidage est reporté ; le prochain accès vide d'abord.
  @Test func clearingDefersTheWipeWhileTheKeychainIsStuck() throws {
    let fixture = try Fixture(installed: true)
    try fixture.base.set(Data("old".utf8), forKey: "session")
    fixture.base.failsEverything = true
    #expect(throws: refused) { try fixture.store.data(forKey: "session") }
    fixture.clock.advance(by: .seconds(15))
    #expect(throws: refused) { try fixture.store.clear() }
    fixture.clock.advance(by: .seconds(15))
    try fixture.store.clear()
    #expect(fixture.store.monitor.isStuck)
    #expect(fixture.defaults.object(forKey: AuthBootstrap.installedFlag) == nil)
    #expect(fixture.store.isWipePending)
    // Toujours bloqué : rien ne se lit, pas même la session d'avant.
    #expect(throws: refused) { try fixture.store.data(forKey: "session") }

    fixture.base.failsEverything = false
    fixture.base.forgetOperations()
    #expect(try fixture.store.data(forKey: "session") == nil)
    #expect(fixture.base.operations == ["removeAll", "data:session"])
    #expect(!fixture.store.isWipePending)
    #expect(!fixture.store.monitor.isStuck)
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
    await #expect(throws: RemoteError.keychainLocked) { try await gateway.ensureSession() }
  }

  @Test func sentinelRoundTripsOnARealKeychain() throws {
    let store = KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")
    try store.verifyAvailable()
    try store.removeAll()
  }
}
