import Foundation

/// Curseurs de descente. Rien de personnel : de simples dates.
nonisolated protocol SyncCursors: Sendable {
  /// Compte auquel se rapportent `lists` et `items`. Le catalogue est commun.
  var accountId: UUID? { get set }
  var lists: Date? { get set }
  var items: Date? { get set }
  var catalog: Date? { get set }
  /// Plus récente pierre tombale descendue (#87), ou heure du serveur à la dernière réconciliation complète.
  var tombstones: Date? { get set }
}

nonisolated struct UserDefaultsSyncCursors: SyncCursors, @unchecked Sendable {
  private let defaults: UserDefaults

  /// Toutes les clés des curseurs : la suppression du compte les efface (`LocalDataPurge`).
  static let keys = [
    "sync.cursor.account", "sync.cursor.lists", "sync.cursor.items", "sync.cursor.catalog", "sync.cursor.tombstones",
  ]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// Oublie tous les curseurs : la prochaine descente repart de zéro, et aucun compte n'est plus attendu.
  func removeAll() {
    for key in Self.keys { defaults.removeObject(forKey: key) }
  }

  var accountId: UUID? {
    get { defaults.string(forKey: "sync.cursor.account").flatMap(UUID.init(uuidString:)) }
    nonmutating set { defaults.set(newValue?.uuidString, forKey: "sync.cursor.account") }
  }
  var lists: Date? {
    get { defaults.object(forKey: "sync.cursor.lists") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.lists") }
  }
  var items: Date? {
    get { defaults.object(forKey: "sync.cursor.items") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.items") }
  }
  var catalog: Date? {
    get { defaults.object(forKey: "sync.cursor.catalog") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.catalog") }
  }
  var tombstones: Date? {
    get { defaults.object(forKey: "sync.cursor.tombstones") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.tombstones") }
  }
}
