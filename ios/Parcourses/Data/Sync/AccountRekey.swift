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

/// Reprise après un changement de compte (session perdue, connexion à un compte e-mail existant) : le nouveau compte
/// ne voit aucune ligne de l'ancien, et un même identifiant y serait ignoré en silence (`on conflict do nothing`). Tout
/// change donc d'identifiant, et tout repart sauf les visites reçues et closes.
///
/// Sort de chaque liste (#87 §2.3, vecteur `008`) : une liste d'autrui (`ownerId` connu, différent de l'ancien compte)
/// est retirée de l'appareil sans être renvoyée, une liste vide jamais modifiée aussi. Un article renvoyé perd un
/// `productId` absent du cache des produits publiés (#69) : le serveur le refuserait (`23503`), il sera résolu à nouveau.
///
/// Une seule sauvegarde : tout ou rien. Rejouable : tant que le compte n'est pas acquitté, aucun envoi n'a lieu,
/// et ces identifiants n'existent nulle part ; recommencer n'a donc aucun effet visible.
/// Sur le MainActor, donc jamais entrelacée avec une écriture d'écran.
enum AccountRekey {
  /// Nombre de listes qui seront renvoyées au nouveau compte (« Les 2 listes de ce téléphone… »).
  static func resendCount(in context: ModelContext, previousAccountId: UUID?) throws -> Int {
    let lists = try context.fetch(FetchDescriptor<ShoppingList>())
    let counts = try itemCounts(in: context)
    return lists.filter { plan(of: $0, itemCount: counts[$0.id] ?? 0, previousAccountId: previousAccountId) == .resend }
      .count
  }

  /// `previousAccountId` inconnu : une liste au propriétaire connu ne peut pas être prouvée à soi, elle n'est pas
  /// renvoyée (une copie privée de la liste d'autrui serait pire qu'une liste qui reste sur l'ancien compte).
  private static func plan(of list: ShoppingList, itemCount: Int, previousAccountId: UUID?) -> RekeyPlan {
    let state = RekeyListState(
      ownerId: list.ownerId, deleted: list.deletedAt != nil, itemCount: itemCount, createdAt: list.createdAt,
      updatedAt: list.updatedAt)
    return SyncDecisions.rekeyPlan(previousAccountId: previousAccountId ?? UUID(), list: state)
  }

  private static func itemCounts(in context: ModelContext) throws -> [UUID: Int] {
    Dictionary(grouping: try context.fetch(FetchDescriptor<ListItem>()), by: \.listId).mapValues(\.count)
  }

  /// `previousAccountKind` : un ancien compte e-mail n'est jamais repris (README des vecteurs) ; ses listes, articles,
  /// visites et entrées quittent l'appareil, ils restent chez lui sur le serveur.
  static func run(
    in context: ModelContext, previousAccountId: UUID?, previousAccountKind: AccountKind = .anonymous, now: Date
  ) throws -> IdentifierRemap {
    if previousAccountKind == .email { return try leaveEmailAccountData(in: context) }
    return try context.atomically {
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
      let counts = Dictionary(grouping: items, by: \.listId).mapValues(\.count)
      let published = Set(try context.fetch(FetchDescriptor<Product>()).map(\.id))
      // Liste supprimée par l'utilisateur (sa suppression s'achève ici), liste d'autrui, liste vide jamais modifiée :
      // retirées de l'appareil avec leurs articles, jamais renvoyées.
      var removed: Set<UUID> = []
      var kept: [ShoppingList] = []
      for list in lists {
        if plan(of: list, itemCount: counts[list.id] ?? 0, previousAccountId: previousAccountId) == .resend {
          kept.append(list)
        } else {
          removed.insert(list.id)
          context.delete(list)
        }
      }
      for item in items where removed.contains(item.listId) { context.delete(item) }

      var alive: Set<UUID> = []
      for list in kept {
        list.id = fresh(list.id)
        list.syncState = .pending
        // Nouvelle ligne, jamais descendue : elle appartiendra au nouveau compte.
        list.ownerId = nil
        alive.insert(list.id)
        try context.enqueueUpsert(of: list, at: now)
      }
      for item in items where !removed.contains(item.listId) {
        item.id = fresh(item.id)
        item.isOnServer = false
        item.updatedBy = nil
        guard let listId = identifiers[item.listId] else {
          // Orphelin : sans liste à envoyer, le serveur le refuserait. Il reste en local, sans entrée.
          item.syncState = .failed
          continue
        }
        item.listId = listId
        item.syncState = .pending
        if let productId = item.productId, !published.contains(productId) { item.productId = nil }
        try context.enqueueUpsert(of: item, at: now, changedFields: ListItemFields.all)
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

extension AccountRekey {
  /// Ancien compte e-mail : rien n'est renvoyé, ses données quittent l'appareil. Tout ou rien.
  fileprivate static func leaveEmailAccountData(in context: ModelContext) throws -> IdentifierRemap {
    try context.atomically {
      try context.delete(model: OutboxEntry.self)
      try context.delete(model: Check.self)
      try context.delete(model: Visit.self)
      try context.delete(model: ListItem.self)
      try context.delete(model: ShoppingList.self)
      return IdentifierRemap(identifiers: [:])
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
