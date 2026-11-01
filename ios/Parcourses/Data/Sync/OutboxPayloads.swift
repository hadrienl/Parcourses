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

  private init(_ other: CheckPayload, checkedAt: Date) {
    id = other.id
    visitId = other.visitId
    productId = other.productId
    categoryId = other.categoryId
    self.checkedAt = checkedAt
  }

  func with(checkedAt: Date) -> CheckPayload {
    CheckPayload(self, checkedAt: checkedAt)
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

/// Ce qu'une entrée attend, et ce qu'elle retient tant qu'elle n'est pas partie.
nonisolated struct OutboxDependency: Sendable, Equatable {
  let waits: Set<String>
  let blocks: Set<String>
}

/// Dépendances entre entrées (#9 §5.2). Une visite attend sa liste : envoyée trop tôt, elle recevrait un
/// `42501` trompeur. Les coches n'attendent que la création de leur visite, et jamais les autres coches ; la
/// clôture attend toutes les coches.
nonisolated enum OutboxDependencies {
  /// `nil` si la charge utile est illisible.
  static func dependency(of entry: OutboxEntry) -> OutboxDependency? {
    switch entry.kind {
    case .upsertList:
      let key: Set = ["list:\(entry.entityId)"]
      return OutboxDependency(waits: key, blocks: key)
    case .deleteList:
      let key = "list:\(entry.entityId)"
      return OutboxDependency(waits: [key, "items:\(entry.entityId)"], blocks: [key])
    case .upsertItem, .deleteItem:
      // Un article en retard ne retient pas les autres articles de sa liste, seulement la suppression de celle-ci.
      guard let listId = listId(of: entry) else { return nil }
      let own = "item:\(entry.entityId)"
      return OutboxDependency(waits: ["list:\(listId)", own], blocks: ["items:\(listId)", own])
    case .createVisit:
      guard let row = try? OutboxCoding.decode(VisitInsert.self, from: entry.payload) else { return nil }
      return OutboxDependency(
        waits: Set(row.listId.map { ["list:\($0)"] } ?? []), blocks: ["create:\(row.id)"])
    case .insertChecks:
      guard let visitId = visitId(of: entry) else { return nil }
      return OutboxDependency(waits: ["create:\(visitId)"], blocks: ["check:\(visitId)"])
    case .closeVisit:
      return OutboxDependency(waits: ["create:\(entry.entityId)", "check:\(entry.entityId)"], blocks: [])
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

extension OutboxKind {
  /// L'horodatage part tel quel, et le serveur le refuse s'il est trop loin dans le futur.
  nonisolated var carriesDeviceTime: Bool {
    switch self {
    case .createVisit, .insertChecks, .closeVisit: true
    case .upsertList, .deleteList, .upsertItem, .deleteItem: false
    }
  }
}

/// Horloge du serveur, lue dans l'en-tête `Date` : aucune migration, et toute réponse en porte un.
nonisolated struct ServerClock: Sendable {
  /// Marge sous les 5 min de `guard_visit` et `guard_check` : l'en-tête arrondit à la seconde et le trajet compte.
  static let futureMargin: TimeInterval = 240

  let serverNow: Date
  let deviceNow: Date

  /// Date à envoyer à la place de `date`, `nil` si `date` n'est pas trop loin dans le futur.
  ///
  /// L'avance mesurée s'ôte à toutes les dates, ce qui garde l'ordre des coches. Le plafond couvre une horloge
  /// remise à l'heure entre-temps : l'avance mesurée est alors nulle alors que `date` reste dans le futur.
  func corrected(_ date: Date) -> Date? {
    guard date > serverNow.addingTimeInterval(Self.futureMargin) else { return nil }
    let lead = max(0, deviceNow.timeIntervalSince(serverNow))
    return min(date.addingTimeInterval(-lead), serverNow)
  }

  static func parseHTTPDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
  }
}
