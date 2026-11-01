import Domain
import Foundation
import OSLog
import SwiftData

/// Lot prêt à partir, sans objet SwiftData : il traverse les acteurs.
nonisolated struct OutboxWork: Sendable, Equatable {
  let entryIds: [UUID]
  let kind: OutboxKind
  let entityId: UUID
  let payloads: [Data]
  let attempts: Int
}

/// Ce qu'il faut savoir d'un article pour le créer localement à la descente.
nonisolated struct PulledItemClassification: Sendable {
  let normalizedName: String
  let categoryId: String
}

/// Accès SwiftData de la synchronisation, sur son propre contexte. N'alloue jamais de `sequence`.
@ModelActor
actor SyncStore {
  private static let logger = Logger(subsystem: "app.parcourses", category: "sync")
  /// Taille d'un insert groupé de coches (#9 §5.2).
  static let maxChecksPerBatch = 200

  // MARK: - File

  /// Première entrée due dont aucune dépendance antérieure n'attend. Les coches d'une visite sont regroupées,
  /// sauf si `singleChecks` contient la visite : un lot refusé est renvoyé ligne à ligne pour isoler la fautive.
  func nextWork(now: Date, singleChecks: Set<UUID> = []) throws -> OutboxWork? {
    var blocked: Set<String> = []
    for entry in try pendingEntries() {
      guard let kind = entry.kind, let keys = OutboxDependencies.keys(of: entry) else {
        // Écrite par une autre version de l'app : la rejouer ne changerait rien.
        entry.syncState = .failed
        entry.lastError = "entrée illisible"
        try modelContext.save()
        Self.logger.error("Entrée de file illisible abandonnée")
        continue
      }
      if !blocked.isDisjoint(with: keys) || entry.nextAttemptAt > now {
        blocked.formUnion(keys)
        continue
      }
      if kind == .insertChecks, let visitId = OutboxDependencies.visitId(of: entry),
        !singleChecks.contains(visitId)
      {
        return try checksBatch(from: entry, visitId: visitId, now: now)
      }
      return work(of: [entry], kind: kind)
    }
    return nil
  }

  /// Prochaine échéance future d'une entrée en attente.
  func nextDueDate(after now: Date) throws -> Date? {
    try pendingEntries().map(\.nextAttemptAt).filter { $0 > now }.min()
  }

  func pendingCount() throws -> Int {
    try pendingEntries().count
  }

  /// Une entrée absente a été remplacée pendant l'envoi : rien à faire, sa remplaçante partira.
  func complete(_ work: OutboxWork) throws {
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      let entityId = entry.entityId
      modelContext.delete(entry)
      try applyToEntity(kind: work.kind, entityId: entityId, state: .synced)
    }
    try modelContext.save()
  }

  /// Erreur définitive : journalisée, plus jamais rejouée (#9 §5.3).
  func fail(_ work: OutboxWork, reason: String) throws {
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      entry.syncState = .failed
      entry.lastError = reason
      try applyToEntity(kind: work.kind, entityId: entry.entityId, state: .failed)
    }
    try modelContext.save()
    Self.logger.error("Entrée abandonnée (\(work.kind.rawValue, privacy: .public)) : \(reason, privacy: .public)")
  }

  /// La visite n'a pas pu être créée : ses coches et sa clôture n'ont plus d'objet.
  func failVisit(_ visitId: UUID, reason: String) throws {
    for entry in try pendingEntries() where OutboxDependencies.visitId(of: entry) == visitId {
      entry.syncState = .failed
      entry.lastError = reason
    }
    for check in try modelContext.fetch(FetchDescriptor<Check>(predicate: #Predicate { $0.visitId == visitId })) {
      check.syncState = .failed
    }
    if let visit = try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitId })).first {
      visit.syncState = .failed
      visit.endSyncState = .failed
    }
    try modelContext.save()
    Self.logger.error("Visite abandonnée : \(reason, privacy: .public)")
  }

  func postpone(_ work: OutboxWork, attempts: Int, until date: Date, reason: String) throws {
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      entry.attempts = attempts
      entry.nextAttemptAt = date
      entry.lastError = reason
    }
    try modelContext.save()
  }

  /// La liste de la visite n'existe plus côté serveur : la visite repart sans elle.
  func removeListFromCreation(_ work: OutboxWork) throws {
    guard let id = work.entryIds.first, let entry = try entry(id: id) else { return }
    let row = try OutboxCoding.decode(VisitInsert.self, from: entry.payload)
    entry.payload = try OutboxCoding.encode(
      VisitInsert(
        id: row.id, storeId: row.storeId, listId: nil, listWasSorted: row.listWasSorted, startedAt: row.startedAt))
    try modelContext.save()
  }

  // MARK: - Descente

  /// Dernier écrit gagne, sauf entrée en attente : le local partira ensuite (#9 §5.4). Renvoie vrai si un
  /// élément a changé.
  func merge(lists rows: [ListRow]) throws -> Bool {
    let pending = try pendingEntityIds()
    var changed = false
    for row in rows where !pending.contains(row.id) {
      let id = row.id
      if let local = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id })).first
      {
        guard local.deletedAt == nil, row.updatedAt >= local.updatedAt else { continue }
        changed = changed || local.name != row.name
        local.name = row.name
        local.updatedAt = row.updatedAt
        local.syncState = .synced
      } else {
        modelContext.insert(
          ShoppingList(
            id: row.id, name: row.name, createdAt: row.createdAt, updatedAt: row.updatedAt, syncState: .synced))
        changed = true
      }
    }
    try modelContext.save()
    return changed
  }

  /// `categoryId`, `notFoundAt` et `position` sont locaux : ils ne sont calculés qu'à la création ou si le
  /// libellé change.
  func merge(
    items rows: [ListItemRow], classify: @Sendable (String) -> PulledItemClassification
  ) throws -> Bool {
    let pending = try pendingEntityIds()
    var changed = false
    for row in rows where !pending.contains(row.id) {
      let id = row.id
      let listId = row.listId
      let lists = try modelContext.fetch(
        FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId && $0.deletedAt == nil }))
      guard !lists.isEmpty else { continue }
      if let local = try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == id })).first {
        guard row.updatedAt >= local.updatedAt else { continue }
        if local.label != row.label {
          let classification = classify(row.label)
          local.label = row.label
          local.normalizedName = classification.normalizedName
          local.categoryId = try categoryId(productId: row.productId) ?? classification.categoryId
        }
        changed =
          changed || local.quantity != row.quantity || local.checkedAt != row.checkedAt
          || local.productId != row.productId
        local.listId = row.listId
        local.quantity = row.quantity
        local.productId = row.productId
        local.checkedAt = row.checkedAt
        local.updatedAt = row.updatedAt
        local.syncState = .synced
      } else {
        let classification = classify(row.label)
        var descriptor = FetchDescriptor<ListItem>(
          predicate: #Predicate { $0.listId == listId }, sortBy: [SortDescriptor(\.position, order: .reverse)])
        descriptor.fetchLimit = 1
        let position = (try modelContext.fetch(descriptor).first?.position ?? -1) + 1
        modelContext.insert(
          ListItem(
            id: row.id, listId: row.listId, label: row.label, normalizedName: classification.normalizedName,
            quantity: row.quantity, productId: row.productId,
            categoryId: try categoryId(productId: row.productId) ?? classification.categoryId,
            checkedAt: row.checkedAt, position: position, updatedAt: row.updatedAt, syncState: .synced))
        changed = true
      }
    }
    try modelContext.save()
    return changed
  }

  /// `shared/categories/` fait foi : aucun id local n'est jamais supprimé ni ajouté ici.
  func applyCategories(_ rows: [CategoryRow]) throws {
    try modelContext.applyRemoteCategoryIds(rows)
    try modelContext.save()
  }

  /// Remplacement du cache. Une réponse vide ne l'efface pas : elle n'apprend rien sur le catalogue.
  func replaceProducts(_ rows: [RemoteProduct]) throws {
    let known = Set(try modelContext.fetch(FetchDescriptor<Category>()).map(\.id))
    var existing = Dictionary(
      try modelContext.fetch(FetchDescriptor<Product>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for row in rows {
      // Serveur en avance sur le référentiel embarqué : pas de catégorie, le classifieur prendra le relais.
      let categoryId = row.categorySlug.flatMap { known.contains($0) ? $0 : nil }
      if let product = existing.removeValue(forKey: row.id) {
        product.name = row.name
        product.normalizedName = row.normalizedName
        product.categoryId = categoryId
      } else {
        modelContext.insert(
          Product(id: row.id, name: row.name, normalizedName: row.normalizedName, categoryId: categoryId))
      }
    }
    if !rows.isEmpty { existing.values.forEach(modelContext.delete) }
    try modelContext.save()
  }

  // MARK: - Outils

  private func pendingEntries() throws -> [OutboxEntry] {
    let pending = SyncState.pending.rawValue
    return try modelContext.fetch(
      FetchDescriptor<OutboxEntry>(
        predicate: #Predicate { $0.syncStateRaw == pending }, sortBy: [SortDescriptor(\.sequence)]))
  }

  private func pendingEntityIds() throws -> Set<UUID> {
    Set(try pendingEntries().map(\.entityId))
  }

  private func entry(id: UUID) throws -> OutboxEntry? {
    try modelContext.fetch(FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.id == id })).first
  }

  private func categoryId(productId: UUID?) throws -> String? {
    guard let productId else { return nil }
    return try modelContext.fetch(FetchDescriptor<Product>(predicate: #Predicate { $0.id == productId })).first?
      .categoryId
  }

  private func work(of entries: [OutboxEntry], kind: OutboxKind) -> OutboxWork {
    OutboxWork(
      entryIds: entries.map(\.id), kind: kind, entityId: entries[0].entityId, payloads: entries.map(\.payload),
      attempts: entries.map(\.attempts).max() ?? 0)
  }

  private func checksBatch(from first: OutboxEntry, visitId: UUID, now: Date) throws -> OutboxWork {
    var batch: [OutboxEntry] = []
    for entry in try pendingEntries() where entry.sequence >= first.sequence {
      guard OutboxDependencies.visitId(of: entry) == visitId else { continue }
      guard entry.kind == .insertChecks, entry.nextAttemptAt <= now, batch.count < Self.maxChecksPerBatch else {
        break
      }
      batch.append(entry)
    }
    return work(of: batch, kind: .insertChecks)
  }

  private func applyToEntity(kind: OutboxKind, entityId: UUID, state: SyncState) throws {
    // Une entrée plus récente de la même entité garde celle-ci en attente.
    let isStillPending = try pendingEntityIds().contains(entityId)
    switch kind {
    case .upsertList:
      guard !isStillPending else { return }
      try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == entityId })).first?
        .syncState = state
    case .upsertItem:
      guard !isStillPending else { return }
      try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == entityId })).first?
        .syncState = state
    case .deleteList:
      guard state == .synced else { return }
      // Le serveur a supprimé les articles en cascade : la suppression douce devient définitive.
      try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.listId == entityId }))
        .forEach(modelContext.delete)
      try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == entityId }))
        .forEach(modelContext.delete)
    case .deleteItem:
      break
    case .createVisit:
      try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == entityId })).first?.syncState =
        state
    case .insertChecks:
      try modelContext.fetch(FetchDescriptor<Check>(predicate: #Predicate { $0.id == entityId })).first?.syncState =
        state
    case .closeVisit:
      try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == entityId })).first?.endSyncState =
        state
    }
  }
}
