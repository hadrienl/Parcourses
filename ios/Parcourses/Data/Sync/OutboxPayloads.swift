import Foundation

/// Charges utiles de la file. Le codage reste local à l'appareil : aucune contrainte de format réseau.
nonisolated enum OutboxCoding {
  static func encode(_ value: some Encodable) throws -> Data {
    try JSONEncoder().encode(value)
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    try JSONDecoder().decode(type, from: data)
  }
}

nonisolated struct ItemDeletionPayload: Codable, Sendable {
  let listId: UUID
}

nonisolated struct VisitClosePayload: Codable, Sendable {
  let visitId: UUID
  let endedAt: Date
}

/// Coche en file : `productId` xor `categoryId`, comme le modèle local.
nonisolated struct CheckPayload: Codable, Sendable, Equatable {
  let id: UUID
  let visitId: UUID
  let productId: UUID?
  let categoryId: String?
  let checkedAt: Date

  init(_ check: Check) {
    id = check.id
    visitId = check.visitId
    productId = check.productId
    categoryId = check.categoryId
    checkedAt = check.checkedAt
  }

  /// `nil` si la coche ne désigne rien : elle ne pourra jamais être envoyée.
  var upload: CheckUpload? {
    if let productId { return CheckUpload(id: id, visitId: visitId, target: .product(productId), checkedAt: checkedAt) }
    if let categoryId {
      return CheckUpload(id: id, visitId: visitId, target: .category(slug: categoryId), checkedAt: checkedAt)
    }
    return nil
  }
}

/// Dépendances entre entrées : une entrée attend toute entrée antérieure en attente qui partage une de ses clés
/// (#9 §5.2). Une visite attend aussi sa liste : envoyée trop tôt, elle recevrait un `42501` trompeur.
nonisolated enum OutboxDependencies {
  /// `nil` si la charge utile est illisible.
  static func keys(of entry: OutboxEntry) -> Set<String>? {
    switch entry.kind {
    case .upsertList, .deleteList:
      return ["list:\(entry.entityId)"]
    case .upsertItem, .deleteItem:
      return listId(of: entry).map { ["list:\($0)"] }
    case .createVisit:
      guard let row = try? OutboxCoding.decode(VisitInsert.self, from: entry.payload) else { return nil }
      return Set(["visit:\(row.id)"] + (row.listId.map { ["list:\($0)"] } ?? []))
    case .insertChecks:
      return visitId(of: entry).map { ["visit:\($0)"] }
    case .closeVisit:
      return ["visit:\(entry.entityId)"]
    case nil:
      return nil
    }
  }

  static func listId(of entry: OutboxEntry) -> UUID? {
    switch entry.kind {
    case .upsertItem: (try? OutboxCoding.decode(ListItemUpsert.self, from: entry.payload))?.listId
    case .deleteItem: (try? OutboxCoding.decode(ItemDeletionPayload.self, from: entry.payload))?.listId
    default: nil
    }
  }

  static func visitId(of entry: OutboxEntry) -> UUID? {
    switch entry.kind {
    case .createVisit, .closeVisit: entry.entityId
    case .insertChecks: (try? OutboxCoding.decode(CheckPayload.self, from: entry.payload))?.visitId
    default: nil
    }
  }
}
