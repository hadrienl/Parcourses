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

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name
    case ownerId = "owner_id"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
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

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
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

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, name
    case normalizedName = "normalized_name"
    case categoryId = "category_id"
    case offCode = "off_code"
    case createdAt = "created_at"
  }
}

/// Ligne renvoyée par la RPC `nearby_stores`, pas une table : hors contrat `tables.json`.
nonisolated struct NearbyStoreRow: Decodable, Sendable, Equatable {
  let id: UUID
  let name: String
  let chain: String?
  let address: String?
  let distanceM: Double
  let organicAisle: Bool

  enum CodingKeys: String, CodingKey {
    case id, name, chain, address
    case distanceM = "distance_m"
    case organicAisle = "organic_aisle"
  }

  init(id: UUID, name: String, chain: String?, address: String?, distanceM: Double, organicAisle: Bool = false) {
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
    organicAisle = try container.decodeIfPresent(Bool.self, forKey: .organicAisle) ?? false
  }
}

/// Ligne de la RPC `search_stores`.
nonisolated struct StoreSearchRow: Decodable, Sendable, Equatable {
  let id: UUID
  let name: String
  let chain: String?
  let address: String?
  let organicAisle: Bool

  enum CodingKeys: String, CodingKey {
    case id, name, chain, address
    case organicAisle = "organic_aisle"
  }

  init(id: UUID, name: String, chain: String?, address: String?, organicAisle: Bool = false) {
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
    organicAisle = try container.decodeIfPresent(Bool.self, forKey: .organicAisle) ?? false
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

// Colonnes modifiables uniquement : `id` n'a pas le privilège UPDATE, et un upsert PostgREST
// classique le réécrirait (`on conflict do update set id = …`), d'où mise à jour puis insertion.
nonisolated struct ListPatch: Encodable, Sendable {
  let name: String
}

nonisolated struct ListItemPatch: Encodable, Sendable {
  let listId: UUID
  let productId: UUID?
  let label: String
  let quantity: String?
  let checkedAt: Date?

  enum CodingKeys: String, CodingKey {
    case label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(listId, forKey: .listId)
    try container.encode(productId, forKey: .productId)
    try container.encode(label, forKey: .label)
    try container.encode(quantity, forKey: .quantity)
    try container.encode(checkedAt, forKey: .checkedAt)
  }
}

nonisolated struct VisitClose: Encodable, Sendable {
  let endedAt: Date

  enum CodingKeys: String, CodingKey {
    case endedAt = "ended_at"
  }
}
