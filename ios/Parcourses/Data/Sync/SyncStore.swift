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
  /// `upsertItem` : colonnes modifiées, `nil` pour une entrée écrite avant 87.3 (toute la ligne part).
  var changedFields: [String]?
  /// `upsertItem` : l'article est déjà sur le serveur, l'envoi ne porte que les champs modifiés.
  var isOnServer = false
}

/// Ce qu'il faut savoir d'un article pour le créer localement à la descente.
nonisolated struct PulledItemClassification: Sendable {
  let normalizedName: String
  let categoryId: String
}

/// Résultat d'une fusion descendante.
nonisolated struct PullMerge: Sendable, Equatable {
  var changed = false
  /// Plus grande date sûre pour le curseur : jamais au-delà d'une ligne sautée.
  private(set) var cursor: Date?
  private var oldestSkipped: Date?

  mutating func skip(_ date: Date) {
    oldestSkipped = min(oldestSkipped ?? date, date)
  }

  mutating func finish(_ dates: [Date]) {
    cursor = oldestSkipped ?? dates.max()
  }
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
      guard let kind = entry.kind, let dependency = OutboxDependencies.dependency(of: entry) else {
        // Écrite par une autre version de l'app : la rejouer ne changerait rien.
        entry.syncState = .failed
        entry.lastError = "entrée illisible"
        try modelContext.save()
        Self.logger.error("Entrée de file illisible abandonnée")
        continue
      }
      if !blocked.isDisjoint(with: dependency.waits) || entry.nextAttemptAt > now {
        blocked.formUnion(dependency.blocks)
        continue
      }
      if kind == .insertChecks, let visitId = OutboxDependencies.visitId(of: entry),
        !singleChecks.contains(visitId)
      {
        return try checksBatch(from: entry, visitId: visitId, now: now)
      }
      return try work(of: [entry], kind: kind)
    }
    return nil
  }

  /// Liste d'un article ou d'une visite en file si elle existe encore et n'a pas été reçue par le serveur.
  func unsentListId(of work: OutboxWork) throws -> UUID? {
    guard let payload = work.payloads.first else { return nil }
    let listId: UUID?
    switch work.kind {
    case .upsertItem: listId = (try? OutboxCoding.decode(ListItemUpsert.self, from: payload))?.listId
    case .createVisit: listId = (try? OutboxCoding.decode(VisitInsert.self, from: payload))?.listId
    default: listId = nil
    }
    guard let listId,
      let list = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId })).first,
      list.deletedAt == nil, list.syncState == .pending
    else { return nil }
    return listId
  }

  /// Prochaine échéance future d'une entrée en attente.
  func nextDueDate(after now: Date) throws -> Date? {
    try pendingEntries().map(\.nextAttemptAt).filter { $0 > now }.min()
  }

  func pendingCount() throws -> Int {
    try pendingEntries().count
  }

  /// Vrai si le contexte tourne sur le thread principal : ce serait une erreur de construction.
  func isOnMainThread() -> Bool {
    Thread.isMainThread
  }

  /// Une entrée absente a été remplacée pendant l'envoi : rien à faire, sa remplaçante partira.
  ///
  /// Sauf une création de visite annulée pendant l'envoi (dernière coche retirée) : le serveur a reçu la visite
  /// quand même. Marquée reçue, elle sera close au lieu d'être supprimée en local (#62).
  func complete(_ work: OutboxWork) throws {
    var entities: [UUID] = []
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      entities.append(entry.entityId)
      modelContext.delete(entry)
    }
    if work.kind == .createVisit, entities.isEmpty { entities.append(work.entityId) }
    let pending = try pendingEntityIds()
    for entityId in entities {
      try applyToEntity(kind: work.kind, entityId: entityId, state: .synced, pending: pending)
    }
    // Même remplacée pendant l'envoi, la ligne est arrivée : l'entrée suivante ne doit plus l'insérer (elle serait
    // ignorée) mais la mettre à jour.
    if work.kind == .upsertItem { try item(id: work.entityId)?.isOnServer = true }
    try modelContext.save()
  }

  /// Erreur définitive : journalisée, plus jamais rejouée (#9 §5.3).
  func fail(_ work: OutboxWork, reason: String) throws {
    var entities: [UUID] = []
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      entry.syncState = .failed
      entry.lastError = reason
      entities.append(entry.entityId)
    }
    let pending = try pendingEntityIds()
    for entityId in entities {
      try applyToEntity(kind: work.kind, entityId: entityId, state: .failed, pending: pending)
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
    // Ce qui est déjà arrivé au serveur le reste.
    for check in try modelContext.fetch(FetchDescriptor<Check>(predicate: #Predicate { $0.visitId == visitId }))
    where check.syncState == .pending {
      check.syncState = .failed
    }
    if let visit = try modelContext.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == visitId })).first {
      if visit.syncState == .pending { visit.syncState = .failed }
      if visit.endSyncState == .pending { visit.endSyncState = .failed }
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

  /// Note la première erreur serveur de chaque entrée et renvoie la plus ancienne.
  func markServerFailure(_ work: OutboxWork, at now: Date, reason: String) throws -> Date {
    var oldest = now
    for id in work.entryIds {
      guard let entry = try entry(id: id) else { continue }
      let since = entry.serverFailingSince ?? now
      entry.serverFailingSince = since
      entry.lastError = reason
      oldest = min(oldest, since)
    }
    try modelContext.save()
    return oldest
  }

  /// Corrige les dates envoyées, jamais les dates locales. Toutes les entrées en attente de la visite reçoivent le
  /// même décalage : création, coches de tous les lots et clôture gardent leur ordre. Vrai si une date était trop
  /// loin dans le futur.
  func correctClock(_ work: OutboxWork, clock: ServerClock) throws -> Bool {
    guard let id = work.entryIds.first, let first = try entry(id: id),
      let visitId = OutboxDependencies.visitId(of: first)
    else { return false }
    let entries = try pendingEntries().filter { OutboxDependencies.visitId(of: $0) == visitId }
    let dates = try entries.compactMap { try Self.sentDate(of: $0) }
    guard let latest = dates.max(), let shift = clock.shift(forLatest: latest) else { return false }
    for entry in entries {
      switch entry.kind {
      case .createVisit:
        let row = try OutboxCoding.decode(VisitInsert.self, from: entry.payload)
        entry.payload = try OutboxCoding.encode(
          VisitInsert(
            id: row.id, storeId: row.storeId, listId: row.listId, listWasSorted: row.listWasSorted,
            startedAt: row.startedAt.addingTimeInterval(-shift)))
      case .insertChecks:
        let row = try OutboxCoding.decode(CheckPayload.self, from: entry.payload)
        entry.payload = try OutboxCoding.encode(row.with(checkedAt: row.checkedAt.addingTimeInterval(-shift)))
      case .closeVisit:
        let row = try OutboxCoding.decode(VisitClosePayload.self, from: entry.payload)
        entry.payload = try OutboxCoding.encode(
          VisitClosePayload(visitId: row.visitId, endedAt: row.endedAt.addingTimeInterval(-shift)))
      default:
        break
      }
    }
    try modelContext.save()
    return true
  }

  private static func sentDate(of entry: OutboxEntry) throws -> Date? {
    switch entry.kind {
    case .createVisit: try OutboxCoding.decode(VisitInsert.self, from: entry.payload).startedAt
    case .insertChecks: try OutboxCoding.decode(CheckPayload.self, from: entry.payload).checkedAt
    case .closeVisit: try OutboxCoding.decode(VisitClosePayload.self, from: entry.payload).endedAt
    default: nil
    }
  }

  /// Reprise prouvée après une panne : les lignes mises de côté repartent. Leur départ de panne reste :
  /// une ligne vraiment fautive retourne de côté dès son échec, sans retenir la file.
  func releaseParked(now: Date) throws {
    for entry in try pendingEntries() where entry.serverFailingSince != nil && entry.nextAttemptAt > now {
      entry.nextAttemptAt = now
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

  // MARK: - Produits

  /// Articles à soumettre à `resolve_products`. L'écriture du résultat se fait sur le contexte principal.
  func productCandidates(excluding attempted: [UUID: String], limit: Int) throws -> [ProductCandidate] {
    try ProductResolution.candidates(in: modelContext, excluding: attempted, limit: limit)
  }

  // MARK: - Descente

  /// La ligne serveur s'applique dès qu'aucune entrée n'attend pour cet id : le local partira sinon ensuite
  /// (#9 §5.4). Aucune comparaison de dates : horloge du serveur et de l'appareil ne se comparent pas.
  /// `me` : compte des données. Une liste d'un autre arrive en lecture seule ; `applyMemberships` pose ensuite le vrai
  /// rôle, sans message. Une descente coupée entre les deux ne laisse donc jamais une liste d'autrui en propriétaire.
  /// Sans compte connu, la liste est à soi (comme avant le partage).
  func merge(lists rows: [ListRow], me: UUID?) throws -> PullMerge {
    let pending = try pendingEntityIds()
    var merge = PullMerge()
    for row in rows {
      let id = row.id
      if pending.contains(id) {
        merge.skip(row.updatedAt)
        continue
      }
      if let local = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id })).first
      {
        // Suppression déjà partie ou abandonnée : la ligne disparaîtra du serveur ou restera masquée.
        guard local.deletedAt == nil else { continue }
        merge.changed = merge.changed || local.name != row.name
        local.name = row.name
        // Dates du serveur, toutes les deux : une liste jamais modifiée y garde `updated_at` égal à `created_at`, ce
        // que `AccountRekey` lit (vecteur `008`). L'heure de l'appareil ne s'y compare pas.
        local.createdAt = row.createdAt
        local.updatedAt = row.updatedAt
        local.syncState = .synced
        local.ownerId = row.ownerId
      } else {
        modelContext.insert(
          ShoppingList(
            id: row.id, name: row.name, createdAt: row.createdAt, updatedAt: row.updatedAt, syncState: .synced,
            ownerId: row.ownerId, role: me.map { row.ownerId == $0 } ?? true ? .owner : .viewer))
        merge.changed = true
      }
    }
    try modelContext.save()
    merge.finish(rows.map(\.updatedAt))
    return merge
  }

  /// `categoryId`, `notFoundAt` et `position` sont locaux : ils ne sont calculés qu'à la création ou si le
  /// libellé change.
  func merge(
    items rows: [ListItemRow], classify: @Sendable (String) -> PulledItemClassification
  ) throws -> PullMerge {
    let pending = try pendingEntityIds()
    var merge = PullMerge()
    for row in rows {
      let id = row.id
      let listId = row.listId
      if pending.contains(id) {
        merge.skip(row.updatedAt)
        continue
      }
      guard
        let list = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId }))
          .first
      else {
        // Parent pas encore arrivé : le curseur reste en arrière pour relire cette ligne.
        merge.skip(row.updatedAt)
        continue
      }
      guard list.deletedAt == nil else { continue }
      if let local = try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == id })).first {
        if local.label != row.label {
          let classification = classify(row.label)
          local.label = row.label
          local.normalizedName = classification.normalizedName
          local.categoryId = try categoryId(productId: row.productId) ?? classification.categoryId
          merge.changed = true
        }
        merge.changed =
          merge.changed || local.quantity != row.quantity || local.checkedAt != row.checkedAt
          || local.productId != row.productId
        local.listId = row.listId
        local.quantity = row.quantity
        local.productId = row.productId
        local.checkedAt = row.checkedAt
        local.updatedAt = row.updatedAt
        local.syncState = .synced
        local.isOnServer = true
        local.updatedBy = row.updatedBy
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
            checkedAt: row.checkedAt, position: position, updatedAt: row.updatedAt, syncState: .synced,
            isOnServer: true, updatedBy: row.updatedBy))
        merge.changed = true
      }
    }
    try modelContext.save()
    merge.finish(rows.map(\.updatedAt))
    return merge
  }

  // MARK: - Listes accessibles et suppressions (#87)

  /// Listes locales, supprimées comprises, et si elles ont déjà atteint le serveur (accusées ou descendues).
  func localListStates() throws -> [LocalListState] {
    try modelContext.fetch(FetchDescriptor<ShoppingList>()).map {
      LocalListState(id: $0.id, syncedOnce: $0.ownerId != nil || $0.syncState == .synced)
    }
  }

  /// Réconciliation des listes avec `accessible_list_ids()` (vecteur `005`) : une liste déjà synchronisée absente du
  /// serveur quitte l'appareil avec ses articles et leurs entrées, même en attente. Renvoie aussi les listes à
  /// descendre entièrement.
  func reconcile(listIds accessible: [UUID]) throws -> (decision: ListReconciliation, changed: Bool) {
    let decision = SyncDecisions.reconcileLists(local: try localListStates(), accessible: accessible)
    for listId in decision.remove { try removeList(listId) }
    try modelContext.save()
    return (decision, !decision.remove.isEmpty)
  }

  /// Pierres tombales descendues (vecteur `006`) : l'article local de même id part, entrées comprises (la suppression
  /// gagne). Vrai si un article affiché a disparu.
  func merge(tombstones rows: [TombstoneRow]) throws -> Bool {
    let ids = Set(rows.map(\.id))
    guard !ids.isEmpty else { return false }
    let local = try modelContext.fetch(FetchDescriptor<ListItem>())
    let doomed = Set(SyncDecisions.applyTombstones(localItems: local.map(\.id), tombstones: Array(ids)))
    for item in local where doomed.contains(item.id) { modelContext.delete(item) }
    for entry in try pendingEntries() where ids.contains(entry.entityId) {
      if entry.kind == .upsertItem || entry.kind == .deleteItem { modelContext.delete(entry) }
    }
    try modelContext.save()
    return !doomed.isEmpty
  }

  /// Listes dont les articles sont confrontés au serveur dans une réconciliation complète : déjà synchronisées, pas
  /// supprimées sur l'appareil.
  func reconcilableListIds() throws -> [UUID] {
    try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.deletedAt == nil }))
      .filter { $0.ownerId != nil || $0.syncState == .synced }.map(\.id)
  }

  /// Réconciliation complète (vecteur `007`) : un article local déjà arrivé au serveur et absent de `serverIds` a été
  /// supprimé ailleurs. Un article jamais envoyé reste. Vrai si un article a disparu.
  func reconcileItems(listId: UUID, serverIds: Set<UUID>) throws -> Bool {
    let gone = try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.listId == listId }))
      .filter { $0.isOnServer && !serverIds.contains($0.id) }
    guard !gone.isEmpty else { return false }
    let ids = Set(gone.map(\.id))
    gone.forEach(modelContext.delete)
    for entry in try pendingEntries() where ids.contains(entry.entityId) { modelContext.delete(entry) }
    try modelContext.save()
    return true
  }

  /// Liste rechargée entièrement (`refreshAccess`) : les entrées de ses articles sont jetées, les articles absents du
  /// serveur retirés, puis les lignes du serveur appliquées. `keepingUnsent` (liste à soi) : les articles jamais
  /// envoyés et leurs entrées restent. Vrai si l'affichage a changé.
  func replaceItems(
    listId: UUID, rows: [ListItemRow], keepingUnsent: Bool, classify: @Sendable (String) -> PulledItemClassification
  ) throws -> Bool {
    var changed = false
    let local = try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.listId == listId }))
    let unsent = keepingUnsent ? Set(local.filter { !$0.isOnServer }.map(\.id)) : []
    for entry in try pendingEntries() where entry.kind == .upsertItem || entry.kind == .deleteItem {
      guard OutboxDependencies.listId(of: entry) == listId, !unsent.contains(entry.entityId) else { continue }
      modelContext.delete(entry)
    }
    let serverIds = Set(rows.map(\.id))
    for item in local where !serverIds.contains(item.id) && !unsent.contains(item.id) {
      modelContext.delete(item)
      changed = true
    }
    try modelContext.save()
    return try merge(items: rows, classify: classify).changed || changed
  }

  /// La liste existe-t-elle, est-elle partie au serveur, et à qui est-elle (vecteur `004`) ?
  func listOwnership(_ listId: UUID) throws -> (exists: Bool, synced: Bool, ownerId: UUID?) {
    guard
      let list = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId })).first
    else { return (false, false, nil) }
    return (true, list.syncState != .pending || list.ownerId != nil, list.ownerId)
  }

  /// Liste dont une ligne a disparu du serveur alors qu'elle n'y est plus lisible : retirée de l'appareil.
  func forget(listId: UUID) throws {
    try removeList(listId)
    try modelContext.save()
  }

  /// Liste disparue du serveur (supprimée ailleurs, accès retiré) : retirée de l'appareil, sans enregistrer.
  private func removeList(_ listId: UUID) throws {
    for entry in try pendingEntries() {
      switch entry.kind {
      case .upsertList, .deleteList:
        if entry.entityId == listId { modelContext.delete(entry) }
      case .upsertItem, .deleteItem:
        if OutboxDependencies.listId(of: entry) == listId { modelContext.delete(entry) }
      default:
        break
      }
    }
    try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.listId == listId }))
      .forEach(modelContext.delete)
    try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId }))
      .forEach(modelContext.delete)
  }

  /// `shared/categories/` fait foi : aucun id local n'est jamais supprimé ni ajouté ici.
  func applyCategories(_ rows: [CategoryRow]) throws {
    try modelContext.applyRemoteCategoryIds(rows)
    try modelContext.save()
  }

  /// Remplacement du cache par le catalogue publié (#69). Une réponse vide ne l'efface que si le catalogue était
  /// lisible (`catalogReadable` : les catégories de la même passe sont arrivées) : plus aucun produit n'est publié, et
  /// les noms téléchargés avant ne doivent pas rester sur l'appareil. Sinon elle n'apprend rien sur le catalogue.
  /// Renvoie vrai si le cache a changé : les suggestions de l'écran Liste ouvert sont alors reconstruites.
  @discardableResult
  func replaceProducts(_ rows: [RemoteProduct], catalogReadable: Bool) throws -> Bool {
    var changed = false
    let known = Set(try modelContext.fetch(FetchDescriptor<Category>()).map(\.id))
    var existing = Dictionary(
      try modelContext.fetch(FetchDescriptor<Product>()).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for row in rows {
      // Serveur en avance sur le référentiel embarqué : pas de catégorie, le classifieur prendra le relais.
      let categoryId = row.categorySlug.flatMap { known.contains($0) ? $0 : nil }
      if let product = existing.removeValue(forKey: row.id) {
        if product.name != row.name || product.normalizedName != row.normalizedName
          || product.categoryId != categoryId
        {
          product.name = row.name
          product.normalizedName = row.normalizedName
          product.categoryId = categoryId
          changed = true
        }
      } else {
        modelContext.insert(
          Product(id: row.id, name: row.name, normalizedName: row.normalizedName, categoryId: categoryId))
        changed = true
      }
    }
    if !rows.isEmpty || catalogReadable {
      changed = changed || !existing.isEmpty
      existing.values.forEach(modelContext.delete)
    }
    try modelContext.save()
    return changed
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

  private func item(id: UUID) throws -> ListItem? {
    try modelContext.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == id })).first
  }

  private func entry(id: UUID) throws -> OutboxEntry? {
    try modelContext.fetch(FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.id == id })).first
  }

  private func categoryId(productId: UUID?) throws -> String? {
    guard let productId else { return nil }
    return try modelContext.fetch(FetchDescriptor<Product>(predicate: #Predicate { $0.id == productId })).first?
      .categoryId
  }

  private func work(of entries: [OutboxEntry], kind: OutboxKind) throws -> OutboxWork {
    var work = OutboxWork(
      entryIds: entries.map(\.id), kind: kind, entityId: entries[0].entityId, payloads: entries.map(\.payload),
      attempts: entries.map(\.attempts).max() ?? 0)
    if kind == .upsertItem {
      work.changedFields = entries[0].changedFields
      work.isOnServer = try item(id: entries[0].entityId)?.isOnServer ?? false
    }
    return work
  }

  private func checksBatch(from first: OutboxEntry, visitId: UUID, now: Date) throws -> OutboxWork {
    var batch: [OutboxEntry] = []
    for entry in try pendingEntries() where entry.sequence >= first.sequence {
      guard OutboxDependencies.visitId(of: entry) == visitId else { continue }
      guard entry.kind == .insertChecks, entry.nextAttemptAt <= now else { continue }
      guard batch.count < Self.maxChecksPerBatch else { break }
      batch.append(entry)
    }
    return try work(of: batch, kind: .insertChecks)
  }

  /// `pending` : une entrée plus récente de la même entité garde celle-ci en attente.
  private func applyToEntity(kind: OutboxKind, entityId: UUID, state: SyncState, pending: Set<UUID>) throws {
    let isStillPending = pending.contains(entityId)
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
