import Foundation
import SwiftData

/// Article saisi librement, sans produit : candidat à `resolve_products`.
nonisolated struct ProductCandidate: Sendable, Equatable {
  let itemId: UUID
  /// Libellé envoyé : la réponse ne s'applique que s'il n'a pas changé entre-temps.
  let label: String
  let categorySlug: String?

  var request: ProductResolutionRequest { ProductResolutionRequest(name: label, categorySlug: categorySlug) }
}

/// Produit obtenu pour un candidat.
nonisolated struct ProductMatch: Sendable, Equatable {
  let candidate: ProductCandidate
  let productId: UUID
  let name: String
  let normalizedName: String
  let categorySlug: String?

  /// `nil` si le serveur n'a ni trouvé ni créé de produit.
  init?(_ candidate: ProductCandidate, _ row: ResolvedProductRow) {
    guard let id = row.id, let name = row.name, let normalizedName = row.normalizedName else { return nil }
    self.candidate = candidate
    productId = id
    self.name = name
    self.normalizedName = normalizedName
    categorySlug = row.categorySlug
  }
}

/// Apprentissage sans catalogue : un article saisi librement reçoit le produit partagé de son libellé, pour que
/// ses coches nourrissent le graphe du magasin.
nonisolated enum ProductResolution {
  /// Articles sans produit, hors listes supprimées. `attempted` : libellé déjà soumis pour cet article.
  static func candidates(
    in context: ModelContext, excluding attempted: [UUID: String], limit: Int
  ) throws -> [ProductCandidate] {
    let deletedLists = Set(
      try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.deletedAt != nil })).map(\.id))
    let slugs = Dictionary(
      try context.fetch(FetchDescriptor<Category>()).map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
    // Ordre total : les mêmes articles partent d'abord, quel que soit l'ordre du store.
    let items = try context.fetch(
      FetchDescriptor<ListItem>(
        predicate: #Predicate { $0.productId == nil }, sortBy: [SortDescriptor(\.updatedAt), SortDescriptor(\.id)]))
    var candidates: [ProductCandidate] = []
    for item in items where candidates.count < limit {
      guard !deletedLists.contains(item.listId), attempted[item.id] != item.label,
        !item.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { continue }
      candidates.append(
        ProductCandidate(itemId: item.id, label: item.label, categorySlug: slugs[item.categoryId] ?? item.categoryId))
    }
    return candidates
  }

  /// Sur le contexte principal : seul lui allonge la file. L'article reçoit son produit et repart au serveur ;
  /// ses coches encore en file désignent désormais le produit au lieu de la catégorie. La catégorie locale de
  /// l'article ne change pas : il resterait sinon à sa place à l'écran jusqu'au prochain tri.
  /// Vrai si une donnée affichée a changé.
  static func apply(_ matches: [ProductMatch], in context: ModelContext, at date: Date) throws -> Bool {
    let localIds = Dictionary(
      try context.fetch(FetchDescriptor<Category>()).map { ($0.slug, $0.id) }, uniquingKeysWith: { first, _ in first })
    let pending = SyncState.pending.rawValue
    var changed = false
    for match in matches {
      let itemId = match.candidate.itemId
      let productId = match.productId
      guard
        let item = try context.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == itemId })).first,
        item.productId == nil, item.label == match.candidate.label
      else { continue }
      let listId = item.listId
      let deleted = FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId && $0.deletedAt != nil })
      guard try context.fetchCount(deleted) == 0 else { continue }

      if try context.fetchCount(FetchDescriptor<Product>(predicate: #Predicate { $0.id == productId })) == 0 {
        context.insert(
          Product(
            id: productId, name: match.name, normalizedName: match.normalizedName,
            categoryId: match.categorySlug.flatMap { localIds[$0] }))
      }

      item.productId = productId
      item.syncState = .pending
      try context.enqueueUpsert(of: item, at: date)

      let checks = try context.fetch(
        FetchDescriptor<Check>(
          predicate: #Predicate { $0.itemId == itemId && $0.productId == nil && $0.syncStateRaw == pending }))
      for check in checks {
        let checkId = check.id
        let entries = try context.fetch(
          FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.entityId == checkId && $0.syncStateRaw == pending }))
        let queued = entries.filter { $0.kind == .insertChecks }
        // Plus en file : la coche est partie ou abandonnée, le serveur la garde telle quelle.
        guard !queued.isEmpty else { continue }
        check.productId = productId
        check.categoryId = nil
        for entry in queued {
          let payload = try OutboxCoding.decode(CheckPayload.self, from: entry.payload)
          entry.payload = try OutboxCoding.encode(payload.with(productId: productId))
        }
      }
      changed = true
    }
    if context.hasChanges { try context.save() }
    return changed
  }
}
