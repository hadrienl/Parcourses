import Foundation

/// Curseurs de descente. Rien de personnel : de simples dates, et des empreintes d'essais de résolution.
nonisolated protocol SyncCursors: Sendable {
  /// Compte auquel se rapportent `lists` et `items`. Le catalogue est commun.
  var accountId: UUID? { get set }
  var lists: Date? { get set }
  var items: Date? { get set }
  var catalog: Date? { get set }
  /// Plus récente date de publication reçue (#47, heure du serveur) : la descente suivante ne lit que les produits
  /// publiés depuis. `nil` : catalogue complet.
  var catalogPublished: Date? { get set }
  /// Dernier téléchargement complet du catalogue (#47) : il est refait chaque semaine.
  var catalogFull: Date? { get set }
  /// Essais de `resolve_products` par article (#47) : une empreinte et une date, rien de lisible.
  var resolutionAttempts: [UUID: ResolutionAttempt] { get set }
  /// Plus récente pierre tombale descendue (#87), ou heure du serveur à la dernière réconciliation complète.
  var tombstones: Date? { get set }
  /// Nature du compte `accountId` : à un changement de compte, seules les données d'un ancien compte anonyme sont
  /// reprises (`AccountRekey`). `nil` (avant 87.3) : anonyme, seule sorte de compte d'alors.
  var accountKind: AccountKind? { get set }
}

nonisolated struct UserDefaultsSyncCursors: SyncCursors, @unchecked Sendable {
  private let defaults: UserDefaults

  /// Toutes les clés des curseurs : la suppression du compte les efface (`LocalDataPurge`).
  static let keys = [
    "sync.cursor.account", "sync.cursor.lists", "sync.cursor.items", "sync.cursor.catalog", "sync.cursor.tombstones",
    "sync.cursor.accountKind", "sync.cursor.catalogPublished", "sync.cursor.catalogFull", "sync.resolutionAttempts",
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
  var catalogPublished: Date? {
    get { defaults.object(forKey: "sync.cursor.catalogPublished") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.catalogPublished") }
  }
  var catalogFull: Date? {
    get { defaults.object(forKey: "sync.cursor.catalogFull") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.catalogFull") }
  }
  /// En JSON. Illisible (format changé) : aucun essai, chaque article repart une fois.
  var resolutionAttempts: [UUID: ResolutionAttempt] {
    get {
      guard let data = defaults.data(forKey: "sync.resolutionAttempts") else { return [:] }
      return (try? JSONDecoder().decode([UUID: ResolutionAttempt].self, from: data)) ?? [:]
    }
    nonmutating set {
      guard !newValue.isEmpty, let data = try? JSONEncoder().encode(newValue) else {
        defaults.removeObject(forKey: "sync.resolutionAttempts")
        return
      }
      defaults.set(data, forKey: "sync.resolutionAttempts")
    }
  }
  var tombstones: Date? {
    get { defaults.object(forKey: "sync.cursor.tombstones") as? Date }
    nonmutating set { defaults.set(newValue, forKey: "sync.cursor.tombstones") }
  }
  var accountKind: AccountKind? {
    get { defaults.string(forKey: "sync.cursor.accountKind").flatMap(AccountKind.init(rawValue:)) }
    nonmutating set { defaults.set(newValue?.rawValue, forKey: "sync.cursor.accountKind") }
  }
}
