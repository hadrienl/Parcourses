import Foundation

/// DTO lié à une table : ses colonnes sont contrôlées contre `shared/contract/tables.json`.
nonisolated protocol TableDTO: Codable, Sendable {
  static var table: String { get }
  static var columns: [String] { get }
}

// MARK: - Lecture

nonisolated struct ListRow: TableDTO, Equatable {
  static let table = "lists"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let ownerId: UUID
  let name: String
  let createdAt: Date
  let updatedAt: Date
  /// Dernier compte à avoir écrit la ligne, `nil` si ce compte a été supprimé. Pas encore affiché (87.4).
  let updatedBy: UUID?

  init(id: UUID, ownerId: UUID, name: String, createdAt: Date, updatedAt: Date, updatedBy: UUID? = nil) {
    self.id = id
    self.ownerId = ownerId
    self.name = name
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.updatedBy = updatedBy
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name
    case ownerId = "owner_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case updatedBy = "updated_by"
  }
}

nonisolated struct ListItemRow: TableDTO, Equatable {
  static let table = "list_items"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let listId: UUID
  let productId: UUID?
  let label: String
  let quantity: String?
  let checkedAt: Date?
  let createdAt: Date
  let updatedAt: Date
  /// Dernier compte à avoir écrit la ligne, `nil` si ce compte a été supprimé.
  let updatedBy: UUID?

  init(
    id: UUID, listId: UUID, productId: UUID?, label: String, quantity: String?, checkedAt: Date?, createdAt: Date,
    updatedAt: Date, updatedBy: UUID? = nil
  ) {
    self.id = id
    self.listId = listId
    self.productId = productId
    self.label = label
    self.quantity = quantity
    self.checkedAt = checkedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.updatedBy = updatedBy
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case updatedBy = "updated_by"
  }
}

/// Trace d'un article supprimé (`list_item_tombstones`, #87). Purgée par le serveur après 30 jours.
nonisolated struct TombstoneRow: TableDTO, Equatable {
  static let table = "list_item_tombstones"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let listId: UUID
  let deletedAt: Date

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case listId = "list_id"
    case deletedAt = "deleted_at"
  }
}

/// Prénom affiché d'un compte e-mail (`profiles`, #87). Un compte anonyme n'en a pas.
nonisolated struct ProfileRow: TableDTO, Equatable {
  static let table = "profiles"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let userId: UUID
  let displayName: String
  let createdAt: Date
  let updatedAt: Date

  enum CodingKeys: String, CodingKey, CaseIterable {
    case userId = "user_id"
    case displayName = "display_name"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

nonisolated struct VisitRow: TableDTO, Equatable {
  static let table = "visits"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let userId: UUID
  let storeId: UUID
  let listId: UUID?
  let listWasSorted: Bool
  let startedAt: Date
  let endedAt: Date?
  let processedAt: Date?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case userId = "user_id"
    case storeId = "store_id"
    case listId = "list_id"
    case listWasSorted = "list_was_sorted"
    case startedAt = "started_at"
    case endedAt = "ended_at"
    case processedAt = "processed_at"
  }
}

nonisolated struct CheckRow: TableDTO, Equatable {
  static let table = "checks"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let visitId: UUID
  let productId: UUID?
  let categoryId: Int16?
  let checkedAt: Date
  let ignored: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, ignored
    case visitId = "visit_id"
    case productId = "product_id"
    case categoryId = "category_id"
    case checkedAt = "checked_at"
  }
}

nonisolated struct CategoryRow: TableDTO, Equatable {
  static let table = "categories"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: Int16
  let slug: String
  let name: String
  let defaultRank: Int16

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, slug, name
    case defaultRank = "default_rank"
  }
}

nonisolated struct ProductRow: TableDTO, Equatable {
  static let table = "products"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let name: String
  let normalizedName: String
  let categoryId: Int16?
  let offCode: String?
  let createdAt: Date
  /// Toujours renseignée : un client ne lit que les produits publiés (#69). Sert de curseur au catalogue (#47).
  let publishedAt: Date?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name
    case normalizedName = "normalized_name"
    case categoryId = "category_id"
    case offCode = "off_code"
    case createdAt = "created_at"
    case publishedAt = "published_at"
  }
}

/// Ligne renvoyée par la RPC `nearby_stores`, pas une table : hors contrat `tables.json`.
nonisolated struct NearbyStoreRow: Decodable, Sendable, Equatable {
  let id: UUID
  let name: String
  let chain: String?
  let address: String?
  let distanceM: Double
  /// `nil` : colonne absente (serveur sans la migration #28), la valeur en cache reste.
  let organicAisle: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, chain, address
    case distanceM = "distance_m"
    case organicAisle = "organic_aisle"
  }

  init(id: UUID, name: String, chain: String?, address: String?, distanceM: Double, organicAisle: Bool? = nil) {
    self.id = id
    self.name = name
    self.chain = chain
    self.address = address
    self.distanceM = distanceM
    self.organicAisle = organicAisle
  }

  /// Colonne facultative : un serveur sans la migration #28 ne doit pas casser le choix du magasin.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    chain = try container.decodeIfPresent(String.self, forKey: .chain)
    address = try container.decodeIfPresent(String.self, forKey: .address)
    distanceM = try container.decode(Double.self, forKey: .distanceM)
    organicAisle = try container.decodeIfPresent(Bool.self, forKey: .organicAisle)
  }
}

/// Ligne de la RPC `search_stores`.
nonisolated struct StoreSearchRow: Decodable, Sendable, Equatable {
  let id: UUID
  let name: String
  let chain: String?
  let address: String?
  /// `nil` : colonne absente (serveur sans la migration #28), la valeur en cache reste.
  let organicAisle: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, chain, address
    case organicAisle = "organic_aisle"
  }

  init(id: UUID, name: String, chain: String?, address: String?, organicAisle: Bool? = nil) {
    self.id = id
    self.name = name
    self.chain = chain
    self.address = address
    self.organicAisle = organicAisle
  }

  /// Colonne facultative, comme pour `NearbyStoreRow`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    chain = try container.decodeIfPresent(String.self, forKey: .chain)
    address = try container.decodeIfPresent(String.self, forKey: .address)
    organicAisle = try container.decodeIfPresent(Bool.self, forKey: .organicAisle)
  }
}

/// Entrée de la RPC `resolve_products` : libellé sans quantité et catégorie choisie par le classifieur.
nonisolated struct ProductResolutionRequest: Encodable, Sendable, Equatable {
  let name: String
  /// Slug partagé. `bio` ou slug inconnu du serveur : le produit n'est pas créé.
  let categorySlug: String?

  enum CodingKeys: String, CodingKey {
    case name
    case categorySlug = "category_slug"
  }
}

/// Ligne de la RPC `resolve_products`, une par entrée envoyée et dans le même ordre.
/// `id` nul : le produit n'existe pas et le serveur ne l'a pas créé (catégorie refusée, quota du jour).
nonisolated struct ResolvedProductRow: Decodable, Sendable, Equatable {
  let normalizedName: String?
  let id: UUID?
  let name: String?
  let categorySlug: String?

  enum CodingKeys: String, CodingKey {
    case id, name
    case normalizedName = "normalized_name"
    case categorySlug = "category_slug"
  }
}

/// Réponse de la RPC `store_graph_snapshot`, sans interprétation du contenu.
nonisolated enum GraphSnapshotResponse: Sendable, Equatable {
  /// La version connue est la version courante.
  case unchanged
  /// Le magasin n'a pas encore d'instantané.
  case none
  /// JSON brut, à conserver tel quel (#9 §4.3).
  case payload(Data)

  static func parse(_ data: Data) -> GraphSnapshotResponse {
    let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    if object == nil || object is NSNull { return .unchanged }
    if let dictionary = object as? [String: Any], dictionary["none"] as? Bool == true { return .none }
    return .payload(data)
  }
}

/// Produit vu par l'app : sa catégorie est le slug partagé, pas l'`Int16` serveur.
nonisolated struct RemoteProduct: Sendable, Equatable {
  let id: UUID
  let name: String
  let normalizedName: String
  let categorySlug: String?
  let offCode: String?
  let createdAt: Date
  /// Curseur du téléchargement incrémental du catalogue (#47).
  var publishedAt: Date? = nil
}

/// Ligne de la RPC `unpublished_products` (#138) : un produit retiré du catalogue commun par un administrateur. Ni
/// libellé ni catégorie : l'identifiant suffit pour le retirer du cache.
nonisolated struct RemoteUnpublishedProduct: Decodable, Sendable, Equatable {
  let id: UUID
  /// Heure du serveur : curseur `catalogUnpublished` de la descente suivante.
  let unpublishedAt: Date

  enum CodingKeys: String, CodingKey {
    case id
    case unpublishedAt = "unpublished_at"
  }
}

// MARK: - Écriture (limitée aux colonnes accordées à `authenticated`)

nonisolated struct ListUpsert: TableDTO, Equatable {
  static let table = "lists"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let name: String

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name
  }
}

nonisolated struct ListItemUpsert: TableDTO, Equatable {
  static let table = "list_items"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let listId: UUID
  let productId: UUID?
  let label: String
  let quantity: String?
  let checkedAt: Date?

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
  }

  // Les `null` sont explicites : une mise à jour doit pouvoir vider une colonne.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(listId, forKey: .listId)
    try container.encode(productId, forKey: .productId)
    try container.encode(label, forKey: .label)
    try container.encode(quantity, forKey: .quantity)
    try container.encode(checkedAt, forKey: .checkedAt)
  }
}

nonisolated struct VisitInsert: TableDTO, Equatable {
  static let table = "visits"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let id: UUID
  let storeId: UUID
  let listId: UUID?
  let listWasSorted: Bool
  let startedAt: Date

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case storeId = "store_id"
    case listId = "list_id"
    case listWasSorted = "list_was_sorted"
    case startedAt = "started_at"
  }
}

/// Une coche porte soit un produit, soit une catégorie (`checks_product_xor_category`).
nonisolated struct CheckInsert: TableDTO, Equatable {
  static let table = "checks"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  enum Target: Sendable, Equatable {
    case product(UUID)
    case category(Int16)
  }

  let id: UUID
  let visitId: UUID
  let productId: UUID?
  let categoryId: Int16?
  let checkedAt: Date

  init(id: UUID, visitId: UUID, target: Target, checkedAt: Date) {
    self.id = id
    self.visitId = visitId
    self.checkedAt = checkedAt
    switch target {
    case .product(let productId):
      self.productId = productId
      self.categoryId = nil
    case .category(let categoryId):
      self.productId = nil
      self.categoryId = categoryId
    }
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id
    case visitId = "visit_id"
    case productId = "product_id"
    case categoryId = "category_id"
    case checkedAt = "checked_at"
  }

  // Les `null` sont explicites : toutes les lignes d'un lot ont les mêmes colonnes.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(visitId, forKey: .visitId)
    try container.encode(productId, forKey: .productId)
    try container.encode(categoryId, forKey: .categoryId)
    try container.encode(checkedAt, forKey: .checkedAt)
  }
}

/// Coche vue par l'app : le gateway traduit le slug en `Int16` au moment de l'envoi.
nonisolated struct CheckUpload: Sendable, Equatable {
  enum Target: Sendable, Equatable {
    case product(UUID)
    case category(slug: String)
  }

  let id: UUID
  let visitId: UUID
  let target: Target
  let checkedAt: Date
}

/// Prénom écrit par le compte lui-même (`profiles`, colonnes accordées : `display_name`).
nonisolated struct ProfilePatch: Encodable, Sendable {
  let displayName: String

  enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
  }
}

// Colonnes modifiables uniquement : `id` n'a pas le privilège UPDATE, et un upsert PostgREST
// classique le réécrirait (`on conflict do update set id = …`), d'où mise à jour puis insertion.
nonisolated struct ListPatch: Encodable, Sendable {
  let name: String
}

/// Mise à jour partielle d'un article : seules les colonnes de `columns` partent, `null` compris (#87 §6.4). Deux
/// membres qui changent des champs différents du même article gardent ainsi tous les deux leur modification.
nonisolated struct ListItemFields: Encodable, Sendable, Equatable {
  static let listId = "list_id"
  static let productId = "product_id"
  static let label = "label"
  static let quantity = "quantity"
  static let checkedAt = "checked_at"
  /// Toutes les colonnes modifiables, triées : entrée écrite avant 87.3 ou article dont on ignore ce qui a changé.
  static let all = [checkedAt, label, listId, productId, quantity]

  let values: ListItemUpsert
  /// Noms de colonnes serveur ; un nom inconnu est ignoré.
  let columns: [String]

  private enum CodingKeys: String, CodingKey {
    case label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    for column in Set(columns) {
      switch CodingKeys(rawValue: column) {
      case .listId: try container.encode(values.listId, forKey: .listId)
      case .productId: try container.encode(values.productId, forKey: .productId)
      case .label: try container.encode(values.label, forKey: .label)
      case .quantity: try container.encode(values.quantity, forKey: .quantity)
      case .checkedAt: try container.encode(values.checkedAt, forKey: .checkedAt)
      case nil: continue
      }
    }
  }
}

nonisolated struct VisitClose: Encodable, Sendable {
  let endedAt: Date

  enum CodingKeys: String, CodingKey {
    case endedAt = "ended_at"
  }
}
