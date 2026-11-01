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

  nonisolated func enqueueUpsert(of list: ShoppingList, at date: Date) throws {
    let kept = try cancelPendingOutboxEntries(entityId: list.id, kinds: [.upsertList])
    try enqueueOutboxEntry(
      kind: .upsertList, entityId: list.id, payload: OutboxCoding.encode(ListUpsert(id: list.id, name: list.name)),
      at: date, keepingSequence: kept)
  }

  nonisolated func enqueueUpsert(of item: ListItem, at date: Date) throws {
    let kept = try cancelPendingOutboxEntries(entityId: item.id, kinds: [.upsertItem])
    let row = ListItemUpsert(
      id: item.id, listId: item.listId, productId: item.productId, label: item.label, quantity: item.quantity,
      checkedAt: item.checkedAt)
    try enqueueOutboxEntry(
      kind: .upsertItem, entityId: item.id, payload: OutboxCoding.encode(row), at: date, keepingSequence: kept)
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

  nonisolated func enqueueDeletion(ofItem id: UUID, listId: UUID, at date: Date) throws {
    try cancelPendingOutboxEntries(entityId: id, kinds: [.upsertItem])
    try enqueueOutboxEntry(
      kind: .deleteItem, entityId: id, payload: OutboxCoding.encode(ItemDeletionPayload(listId: listId)), at: date)
  }

  /// Entrée de création de la visite : différée à la première coche, une visite sans coche ne part jamais (#9 §5.5).
  nonisolated func enqueueCreation(of visit: Visit, listId: UUID?, at date: Date) throws {
    let row = VisitInsert(
      id: visit.id, storeId: visit.storeId, listId: listId, listWasSorted: visit.listWasSorted,
      startedAt: visit.startedAt)
    try enqueueOutboxEntry(kind: .createVisit, entityId: visit.id, payload: OutboxCoding.encode(row), at: date)
  }

  nonisolated func enqueueInsertion(of check: Check, at date: Date) throws {
    try enqueueOutboxEntry(
      kind: .insertChecks, entityId: check.id, payload: OutboxCoding.encode(CheckPayload(check)), at: date)
  }

  nonisolated func enqueueClosure(ofVisit id: UUID, endedAt: Date, at date: Date) throws {
    try enqueueOutboxEntry(
      kind: .closeVisit, entityId: id, payload: OutboxCoding.encode(VisitClosePayload(visitId: id, endedAt: endedAt)),
      at: date)
  }
}
