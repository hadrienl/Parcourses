import Foundation
import OSLog
import Synchronization

/// Keychain de la session tel que l'app l'utilise (#133) : une seule instance, partagée par `SupabaseGateway`,
/// `LocalDataPurge` et `AuthBootstrap`.
///
/// - Chaque accès est noté dans `monitor` : un Keychain qui refuse tout devient « bloqué ».
/// - Vidage en attente : tant que `AuthBootstrap.installedFlag` manque dans `defaults` (réinstallation, ou vidage
///   reporté par `clear()`), toute opération commence par vider le Keychain. Réussi, le drapeau est posé et l'opération
///   continue ; en échec, elle lève sans rien lire ni écrire : une session d'avant ne peut jamais être relue.
/// - `clear()` : vider sans lire. Keychain bloqué, le vidage est reporté au prochain accès et la purge aboutit.
///
/// Les opérations sont faites l'une après l'autre : une lecture ne peut pas passer entre le constat du vidage en attente
/// et le vidage lui-même.
nonisolated final class GuardedSecureStore: SecureStore, @unchecked Sendable {
  private static let logger = Logger(subsystem: "app.parcourses", category: "auth")

  let monitor: KeyAccessMonitor
  private let base: any SecureStore
  /// Documenté sûr d'un fil à l'autre ; seul `AuthBootstrap.installedFlag` y est lu et écrit ici.
  private let defaults: UserDefaults
  private let lock = Mutex(())

  init(base: any SecureStore, defaults: UserDefaults, monitor: KeyAccessMonitor) {
    self.base = base
    self.defaults = defaults
    self.monitor = monitor
  }

  /// Keychain de l'app, surveillé selon la disponibilité des données protégées.
  @MainActor static func live() -> GuardedSecureStore {
    let availability = ProtectedDataAvailability.live()
    return GuardedSecureStore(
      base: KeychainStore(), defaults: .standard,
      monitor: KeyAccessMonitor(isProtectedDataAvailable: { availability.isAvailable }))
  }

  /// Vidage en attente (drapeau absent).
  var isWipePending: Bool { !defaults.bool(forKey: AuthBootstrap.installedFlag) }

  /// Fait le vidage en attente, s'il y en a un. Sans vidage dû, le Keychain n'est pas touché.
  func completePendingWipe() throws {
    try lock.withLock { _ in
      guard isWipePending else { return }
      try monitored { try wipe() }
    }
  }

  func data(forKey key: String) throws -> Data? {
    try access { try base.data(forKey: key) }
  }

  func set(_ data: Data, forKey key: String) throws {
    try access { try base.set(data, forKey: key) }
  }

  func removeValue(forKey key: String) throws {
    try access { try base.removeValue(forKey: key) }
  }

  /// Le vidage en attente, s'il y en a un, est celui-ci.
  func removeAll() throws {
    try lock.withLock { _ in
      try monitored { try wipe() }
    }
  }

  /// Comme `removeAll`, sauf Keychain bloqué (cet échec compris) : le drapeau est retiré, le vidage reporté au prochain
  /// accès, et la purge continue. Une session illisible ne se relira de toute façon pas.
  func clear() throws {
    try lock.withLock { _ in
      do {
        try monitored { try wipe() }
      } catch {
        guard monitor.isStuck else { throw error }
        defaults.removeObject(forKey: AuthBootstrap.installedFlag)
        Self.logger.error(
          "Keychain bloqué, vidage reporté : \(AuthBootstrap.publicCode(of: error), privacy: .public) \(String(describing: error), privacy: .private)"
        )
      }
    }
  }

  /// Vidage en attente d'abord, puis l'opération ; le tout sous le verrou, et noté dans `monitor`.
  private func access<T: Sendable>(_ operation: () throws -> T) throws -> T {
    try lock.withLock { _ in
      try monitored {
        if isWipePending { try wipe() }
        return try operation()
      }
    }
  }

  /// Vide le Keychain, puis pose le drapeau : plus rien d'avant ne peut être relu.
  private func wipe() throws {
    try base.removeAll()
    defaults.set(true, forKey: AuthBootstrap.installedFlag)
  }

  private func monitored<T: Sendable>(_ operation: () throws -> T) throws -> T {
    do {
      let value = try operation()
      monitor.record(success: true)
      return value
    } catch {
      monitor.record(success: false)
      throw error
    }
  }
}
