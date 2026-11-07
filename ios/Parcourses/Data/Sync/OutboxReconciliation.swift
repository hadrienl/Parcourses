import Foundation
import SwiftData

/// Remet la file d'accord avec les données locales (liste, article ou visite `pending` sans entrée active).
///
/// Une donnée peut être `pending` sans entrée : liste créée avant l'existence de la file, entrée perdue, ou
/// abandonnée en `failed` pour une cause qui n'en était pas une (article refusé parce que sa liste n'était jamais
/// partie). Sans entrée, rien ne l'enverrait jamais.
///
/// Rejouable et idempotente : une entité qui a déjà une entrée `pending` n'en reçoit pas de seconde. Les entrées
/// sont ajoutées dans l'ordre des dépendances (liste, articles, visites, coches, clôtures). À appeler depuis le
/// contexte principal, seul autorisé à allonger la file (`sequence`).
enum OutboxReconciliation {
  /// Cause d'un article abandonné à tort : le serveur refuse (`42501`) tant que la liste n'existe pas chez lui.
  static let forbiddenReason = "42501"

  /// Nombre d'entrées ajoutées ou rendues à la file.
  @discardableResult
  static func run(in context: ModelContext, now: Date) throws -> Int {
    try context.atomically {
      var queued = try activeKinds(in: context)
      var count = 0
      func missing(_ id: UUID, _ kind: OutboxKind) -> Bool { !(queued[id]?.contains(kind) ?? false) }
      let pending = SyncState.pending.rawValue

      let lists = try context.fetch(
        FetchDescriptor<ShoppingList>(
          predicate: #Predicate { $0.syncStateRaw == pending }, sortBy: [SortDescriptor(\.createdAt)]))
      for list in lists {
        if list.deletedAt != nil {
          guard missing(list.id, .deleteList) else { continue }
          try context.enqueueDeletion(ofList: list.id, at: now)
          queued[list.id, default: []].insert(.deleteList)
        } else {
          guard missing(list.id, .upsertList) else { continue }
          try context.enqueueUpsert(of: list, at: now)
          queued[list.id, default: []].insert(.upsertList)
        }
        count += 1
      }

      let items = try context.fetch(
        FetchDescriptor<ListItem>(
          predicate: #Predicate { $0.syncStateRaw == pending }, sortBy: [SortDescriptor(\.position)]))
      for item in items where missing(item.id, .upsertItem) {
        guard try isActive(list: item.listId, in: context) else { continue }
        try context.enqueueUpsert(of: item, at: now)
        count += 1
      }
      count += try revokeWrongfulFailures(in: context, now: now)

      let visits = try context.fetch(
        FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.startedAt)]))
      let allChecks = Dictionary(
        grouping: try context.fetch(FetchDescriptor<Check>(sortBy: [SortDescriptor(\.checkedAt)])), by: \.visitId)
      for visit in visits {
        let checks = allChecks[visit.id] ?? []
        // Sans coche, une visite reste locale (#9 §5.5).
        guard !checks.isEmpty else { continue }
        if visit.syncState == .pending, missing(visit.id, .createVisit) {
          let listId = try isActive(list: visit.listId, in: context) ? visit.listId : nil
          try context.enqueueCreation(of: visit, listId: listId, at: now)
          count += 1
        }
        // Visite abandonnée : ses coches n'ont plus d'objet.
        guard visit.syncState != .failed else { continue }
        for check in checks where check.syncState == .pending && missing(check.id, .insertChecks) {
          try context.enqueueInsertion(of: check, at: now)
          count += 1
        }
        if let endedAt = visit.endedAt, visit.endSyncState == .pending, missing(visit.id, .closeVisit) {
          try context.enqueueClosure(ofVisit: visit.id, endedAt: endedAt, at: now)
          count += 1
        }
      }
      return count
    }
  }

  /// Les articles abandonnés en `42501` alors que leur liste n'est jamais partie repartent, derrière elle.
  /// Remplacés par une entrée neuve : la valeur courante de l'article part, jamais une valeur périmée.
  private static func revokeWrongfulFailures(in context: ModelContext, now: Date) throws -> Int {
    let failed = SyncState.failed.rawValue
    let entries = try context.fetch(
      FetchDescriptor<OutboxEntry>(
        predicate: #Predicate { $0.syncStateRaw == failed }, sortBy: [SortDescriptor(\.sequence)]))
    var count = 0
    for entry in entries where entry.kind == .upsertItem && entry.lastError == forbiddenReason {
      guard let listId = OutboxDependencies.listId(of: entry) else { continue }
      let id = entry.entityId
      let list = try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId })).first
      guard let list, list.deletedAt == nil, list.syncState == .pending,
        let item = try context.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == id })).first
      else { continue }
      context.delete(entry)
      let pending = SyncState.pending.rawValue
      let hasActive = try !context.fetch(
        FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.entityId == id && $0.syncStateRaw == pending })
      ).isEmpty
      item.syncState = .pending
      if !hasActive {
        try context.enqueueUpsert(of: item, at: now)
        count += 1
      }
    }
    return count
  }

  private static func activeKinds(in context: ModelContext) throws -> [UUID: Set<OutboxKind>] {
    let pending = SyncState.pending.rawValue
    let entries = try context.fetch(FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.syncStateRaw == pending }))
    var kinds: [UUID: Set<OutboxKind>] = [:]
    for entry in entries {
      if let kind = entry.kind { kinds[entry.entityId, default: []].insert(kind) }
    }
    return kinds
  }

  private static func isActive(list id: UUID, in context: ModelContext) throws -> Bool {
    try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id })).first
      .map { $0.deletedAt == nil } ?? false
  }
}
