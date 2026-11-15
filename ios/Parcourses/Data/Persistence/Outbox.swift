import Foundation
import SwiftData

extension ModelContext {
  /// Ajoute une entrée à la file sans enregistrer : l'appelant la sauvegarde avec l'écriture qu'elle accompagne.
  ///
  /// `sequence` prolonge la plus grande valeur présente, entrées non enregistrées comprises.
  /// La file n'est allongée que depuis le contexte principal.
  @discardableResult
  nonisolated func enqueueOutboxEntry(
    kind: OutboxKind, entityId: UUID, payload: Data, at date: Date, keepingSequence kept: Int64? = nil
  ) throws -> OutboxEntry {
    var descriptor = FetchDescriptor<OutboxEntry>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
    descriptor.fetchLimit = 1
    let sequence = try kept ?? ((fetch(descriptor).first?.sequence ?? 0) + 1)
    let entry = OutboxEntry(
      sequence: sequence, kind: kind, entityId: entityId, payload: payload, createdAt: date, nextAttemptAt: date)
    insert(entry)
    return entry
  }

  /// Retire les entrées en attente de cette entité. Une entrée en cours d'envoi peut disparaître ainsi :
  /// `SyncStore.complete` l'ignore alors, et la nouvelle entrée repart avec la dernière valeur (#9 §5.2).
  /// Renvoie la plus petite `sequence` retirée : la remplaçante la reprend, sinon un renommage ferait passer
  /// la liste derrière ses articles.
  @discardableResult
  nonisolated func cancelPendingOutboxEntries(entityId: UUID, kinds: Set<OutboxKind>) throws -> Int64? {
    let pending = SyncState.pending.rawValue
    let entries = try fetch(
      FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.entityId == entityId && $0.syncStateRaw == pending }))
    var sequence: Int64?
    for entry in entries where entry.kind.map(kinds.contains) == true {
      sequence = min(sequence ?? entry.sequence, entry.sequence)
      delete(entry)
    }
    return sequence
  }

  /// Une modification garde le départ de la panne : sinon, chaque retouche rebloquerait toute la file.
  private nonisolated func serverFailureStart(entityId: UUID) throws -> Date? {
    let pending = SyncState.pending.rawValue
    return try fetch(
      FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.entityId == entityId && $0.syncStateRaw == pending })
    ).compactMap(\.serverFailingSince).min()
  }

  nonisolated func enqueueUpsert(of list: ShoppingList, at date: Date) throws {
    let since = try serverFailureStart(entityId: list.id)
    let kept = try cancelPendingOutboxEntries(entityId: list.id, kinds: [.upsertList])
    let entry = try enqueueOutboxEntry(
      kind: .upsertList, entityId: list.id, payload: OutboxCoding.encode(ListUpsert(id: list.id, name: list.name)),
      at: date, keepingSequence: kept)
    entry.serverFailingSince = since
  }

  /// `changedFields` : colonnes serveur modifiées (`ListItemFields`). L'entrée remplacée lègue les siennes (vecteur
  /// `002`) ; une entrée écrite avant 87.3 (`nil`) le reste, et toute la ligne partira.
  nonisolated func enqueueUpsert(of item: ListItem, at date: Date, changedFields: [String]) throws {
    let since = try serverFailureStart(entityId: item.id)
    let fields = try pendingChangedFields(entityId: item.id)
    let kept = try cancelPendingOutboxEntries(entityId: item.id, kinds: [.upsertItem])
    let row = ListItemUpsert(
      id: item.id, listId: item.listId, productId: item.productId, label: item.label, quantity: item.quantity,
      checkedAt: item.checkedAt)
    let entry = try enqueueOutboxEntry(
      kind: .upsertItem, entityId: item.id, payload: OutboxCoding.encode(row), at: date, keepingSequence: kept)
    entry.serverFailingSince = since
    switch fields {
    case .some(.none): entry.changedFields = nil
    case .some(.some(let pending)):
      entry.changedFields = SyncDecisions.mergeChangedFields(pending: pending, new: changedFields)
    case .none: entry.changedFields = SyncDecisions.mergeChangedFields(pending: nil, new: changedFields)
    }
  }

  /// Champs de l'entrée d'article en attente : `nil` sans entrée, `.some(nil)` pour une entrée écrite avant 87.3.
  private nonisolated func pendingChangedFields(entityId: UUID) throws -> [String]?? {
    let pending = SyncState.pending.rawValue
    let kind = OutboxKind.upsertItem.rawValue
    let entries = try fetch(
      FetchDescriptor<OutboxEntry>(
        predicate: #Predicate { $0.entityId == entityId && $0.syncStateRaw == pending && $0.kindRaw == kind }))
    guard !entries.isEmpty else { return nil }
    if entries.contains(where: { $0.changedFields == nil }) { return .some(nil) }
    return .some(entries.flatMap { $0.changedFields ?? [] })
  }

  /// Plus rien de la liste ni de ses articles ne doit partir avant sa suppression.
  nonisolated func enqueueDeletion(ofList id: UUID, at date: Date) throws {
    let pending = SyncState.pending.rawValue
    let entries = try fetch(FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.syncStateRaw == pending }))
    for entry in entries {
      switch entry.kind {
      case .upsertList where entry.entityId == id:
        delete(entry)
      case .upsertItem, .deleteItem:
        if OutboxDependencies.listId(of: entry) == id { delete(entry) }
      default:
        break
      }
    }
    try enqueueOutboxEntry(kind: .deleteList, entityId: id, payload: Data(), at: date)
  }

  /// `isOnServer` : une suppression sans ligne d'un article jamais accusé n'a rien supprimé, ce n'est pas un refus.
  nonisolated func enqueueDeletion(ofItem id: UUID, listId: UUID, isOnServer: Bool, at date: Date) throws {
    try cancelPendingOutboxEntries(entityId: id, kinds: [.upsertItem])
    try enqueueOutboxEntry(
      kind: .deleteItem, entityId: id,
      payload: OutboxCoding.encode(ItemDeletionPayload(listId: listId, isOnServer: isOnServer)), at: date)
  }

  /// Entrée de création de la visite : différée à la première coche, une visite sans coche ne part jamais (#9 §5.5).
  /// `notBefore` : voir `enqueueInsertion`.
  nonisolated func enqueueCreation(of visit: Visit, listId: UUID?, at date: Date, notBefore: Date? = nil) throws {
    let row = VisitInsert(
      id: visit.id, storeId: visit.storeId, listId: listId, listWasSorted: visit.listWasSorted,
      startedAt: visit.startedAt)
    let entry = try enqueueOutboxEntry(
      kind: .createVisit, entityId: visit.id, payload: OutboxCoding.encode(row), at: date)
    if let notBefore { entry.nextAttemptAt = notBefore }
  }

  /// `notBefore` retient l'envoi le temps de l'annulation : une coche partie est immuable sur le serveur.
  nonisolated func enqueueInsertion(of check: Check, at date: Date, notBefore: Date? = nil) throws {
    let entry = try enqueueOutboxEntry(
      kind: .insertChecks, entityId: check.id, payload: OutboxCoding.encode(CheckPayload(check)), at: date)
    if let notBefore { entry.nextAttemptAt = notBefore }
  }

  nonisolated func enqueueClosure(ofVisit id: UUID, endedAt: Date, at date: Date) throws {
    try enqueueOutboxEntry(
      kind: .closeVisit, entityId: id, payload: OutboxCoding.encode(VisitClosePayload(visitId: id, endedAt: endedAt)),
      at: date)
  }
}
