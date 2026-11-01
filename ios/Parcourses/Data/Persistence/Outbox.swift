import Foundation
import SwiftData

extension ModelContext {
  /// Ajoute une entrée à la file sans enregistrer : l'appelant la sauvegarde avec l'écriture qu'elle accompagne.
  ///
  /// `sequence` prolonge la plus grande valeur présente, entrées non enregistrées comprises.
  /// La file est écrite depuis un seul contexte à la fois : 9.7 devra conserver cette règle.
  @discardableResult
  nonisolated func enqueueOutboxEntry(
    kind: OutboxKind, entityId: UUID, payload: Data, at date: Date
  ) throws -> OutboxEntry {
    var descriptor = FetchDescriptor<OutboxEntry>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
    descriptor.fetchLimit = 1
    let sequence = (try fetch(descriptor).first?.sequence ?? 0) + 1
    let entry = OutboxEntry(
      sequence: sequence, kind: kind, entityId: entityId, payload: payload, createdAt: date, nextAttemptAt: date)
    insert(entry)
    return entry
  }
}
