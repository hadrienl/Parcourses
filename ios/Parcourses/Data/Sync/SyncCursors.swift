import Foundation

/// Curseurs de descente. Rien de personnel : de simples dates.
nonisolated protocol SyncCursors: Sendable {
  /// Compte auquel se rapportent `lists` et `items`. Le catalogue est commun.
  var accountId: UUID? { get set }
  var lists: Date? { get set }
  var items: Date? { get set }
  var catalog: Date? { get set }
}

nonisolated struct UserDefaultsSyncCursors: SyncCursors, @unchecked Sendable {
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
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
}
