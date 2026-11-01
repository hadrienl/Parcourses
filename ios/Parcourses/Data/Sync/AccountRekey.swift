import Foundation
import SwiftData

/// Anciens identifiants vers nouveaux, pour les écrans ouverts.
nonisolated struct IdentifierRemap: Sendable, Equatable {
  static let userInfoKey = "remap"
  let identifiers: [UUID: UUID]

  init(identifiers: [UUID: UUID]) { self.identifiers = identifiers }

  init?(notification: Notification) {
    guard let remap = notification.userInfo?[Self.userInfoKey] as? IdentifierRemap else { return nil }
    self = remap
  }

  subscript(id: UUID) -> UUID { identifiers[id] ?? id }
}

/// Reprise après perte de session : le nouveau compte anonyme ne voit aucune ligne de l'ancien, et un même
/// identifiant y serait ignoré en silence (`on conflict do nothing`). Tout change donc d'identifiant, et tout repart
/// sauf les visites reçues et closes.
///
/// Une seule sauvegarde : tout ou rien. Rejouable : tant que le compte n'est pas acquitté, aucun envoi n'a lieu,
/// et ces identifiants n'existent nulle part ; recommencer n'a donc aucun effet visible.
/// Sur le MainActor, donc jamais entrelacée avec une écriture d'écran.
enum AccountRekey {
  static func run(in context: ModelContext, now: Date) throws -> IdentifierRemap {
    try context.atomically {
      // Sur un contexte neuf : le principal reçoit les écritures du moteur plus tard, et un état `pending` périmé
      // ferait renvoyer une visite déjà reçue.
      let disk = ModelContext(context.container)
      let synced = SyncState.synced.rawValue
      let received = Set(
        try disk.fetch(
          FetchDescriptor<Visit>(predicate: #Predicate { $0.syncStateRaw == synced && $0.endSyncStateRaw == synced })
        ).map(\.id))
      let checkStates = Dictionary(
        try disk.fetch(FetchDescriptor<Check>()).map { ($0.id, $0.syncState) }, uniquingKeysWith: { first, _ in first })

      let entries = try context.fetch(FetchDescriptor<OutboxEntry>())
      // Coche retenue pendant l'annulation : l'envoi reste retenu, sinon elle deviendrait immuable trop tôt.
      var held: [UUID: Date] = [:]
      for entry in entries where entry.syncState == .pending && entry.nextAttemptAt > now {
        held[entry.entityId] = entry.nextAttemptAt
      }
      // Suppressions comprises : le nouveau compte n'a rien à supprimer.
      entries.forEach(context.delete)

      var identifiers: [UUID: UUID] = [:]
      let fresh: (UUID) -> UUID = { old in
        let new = UUID()
        identifiers[old] = new
        return new
      }

      let lists = try context.fetch(FetchDescriptor<ShoppingList>(sortBy: [SortDescriptor(\.createdAt)]))
      let items = try context.fetch(FetchDescriptor<ListItem>(sortBy: [SortDescriptor(\.position)]))
      // Liste supprimée par l'utilisateur : sa suppression s'achève ici, elle ne doit pas réapparaître.
      let deleted = Set(lists.filter { $0.deletedAt != nil }.map(\.id))
      for item in items where deleted.contains(item.listId) { context.delete(item) }
      for list in lists where list.deletedAt != nil { context.delete(list) }

      var alive: Set<UUID> = []
      for list in lists where list.deletedAt == nil {
        list.id = fresh(list.id)
        list.syncState = .pending
        alive.insert(list.id)
        try context.enqueueUpsert(of: list, at: now)
      }
      for item in items where !deleted.contains(item.listId) {
        item.id = fresh(item.id)
        guard let listId = identifiers[item.listId] else {
          // Orphelin : sans liste à envoyer, le serveur le refuserait. Il reste en local, sans entrée.
          item.syncState = .failed
          continue
        }
        item.listId = listId
        item.syncState = .pending
        try context.enqueueUpsert(of: item, at: now)
      }

      let visits = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.startedAt)]))
      let checks = try context.fetch(FetchDescriptor<Check>(sortBy: [SortDescriptor(\.checkedAt)]))
      let checksByVisit = Dictionary(grouping: checks, by: \.visitId)
      for visit in visits {
        let oldVisit = visit.id
        visit.id = fresh(oldVisit)
        visit.listId = identifiers[visit.listId] ?? visit.listId
        let own = checksByVisit[oldVisit] ?? []
        // Reçue et close : elle a pu nourrir le graphe partagé, et la renvoyer l'y apprendrait une seconde fois.
        // Elle reste en local. Visite ouverte ou clôture non reçue : jamais apprise, elle repart en entier.
        guard !received.contains(oldVisit) else {
          visit.syncState = .synced
          visit.endSyncState = .synced
          for check in own {
            let state = checkStates[check.id] ?? .synced
            check.id = fresh(check.id)
            check.visitId = visit.id
            check.itemId = identifiers[check.itemId] ?? check.itemId
            check.syncState = state
          }
          continue
        }
        visit.syncState = .pending
        visit.endSyncState = .pending
        // Sans coche, une visite reste locale (#9 §5.5). Elle partira avec sa première coche.
        guard !own.isEmpty else { continue }
        // Sans sa liste, la visite reste utile au graphe.
        try context.enqueueCreation(
          of: visit, listId: alive.contains(visit.listId) ? visit.listId : nil, at: now, notBefore: held[oldVisit])
        for check in own {
          let oldCheck = check.id
          check.id = fresh(oldCheck)
          check.visitId = visit.id
          check.itemId = identifiers[check.itemId] ?? check.itemId
          check.syncState = .pending
          try context.enqueueInsertion(of: check, at: now, notBefore: held[oldCheck])
        }
        // Après les coches : la RLS refuse toute coche sur une visite close.
        if let endedAt = visit.endedAt { try context.enqueueClosure(ofVisit: visit.id, endedAt: endedAt, at: now) }
      }
      return IdentifierRemap(identifiers: identifiers)
    }
  }
}

/// Reçoit les nouveaux identifiants pendant la vie de son propriétaire.
nonisolated final class IdentifierRemapObserver: @unchecked Sendable {
  private let token: any NSObjectProtocol

  init(_ apply: @escaping @MainActor @Sendable (IdentifierRemap) -> Void) {
    // `queue: nil` : remis de façon synchrone sur le MainActor, avant toute autre écriture d'écran.
    token = NotificationCenter.default.addObserver(forName: .syncDidRekeyData, object: nil, queue: nil) {
      notification in
      guard let remap = IdentifierRemap(notification: notification) else { return }
      MainActor.assumeIsolated { apply(remap) }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(token)
  }
}
