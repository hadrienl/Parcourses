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

  enum CodingKeys: String, CodingKey {
    case id, name, chain, address
    case distanceM = "distance_m"
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
