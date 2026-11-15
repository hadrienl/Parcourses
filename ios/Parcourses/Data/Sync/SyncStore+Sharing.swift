import Foundation
import SwiftData

// Partage (#87, lot 87.4) : rôle durable et participants des listes, relus à la descente et par `refreshAccess`.
extension SyncStore {
  /// Rôles et participants de toutes les listes descendues. Une liste jamais descendue reste à soi. Renvoie les
  /// changements de rôle à annoncer, et si l'affichage a changé.
  func applyMemberships(
    members: [ListMemberRow], profiles: [ProfileRow], me: UUID
  ) throws -> (changes: [SharingAccessChange], changed: Bool) {
    let names = Dictionary(profiles.map { ($0.userId, $0.displayName) }) { first, _ in first }
    var changes: [SharingAccessChange] = []
    var changed = false
    for list in try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.deletedAt == nil })) {
      guard let ownerId = list.ownerId else { continue }
      let resolved = ListMemberships.resolve(
        listId: list.id, ownerId: ownerId, me: me, members: members, names: names)
      if resolved.participants != list.participants {
        list.participants = resolved.participants
        changed = true
      }
      // Sans ligne à mon nom, la liste n'est plus à moi : la réconciliation des listes la retire, le rôle reste.
      guard let role = resolved.role, role != list.role else { continue }
      if let kind = ListMemberships.change(from: list.role, to: role) {
        changes.append(
          SharingAccessChange(listId: list.id, listName: list.name, ownerName: names[ownerId], kind: kind))
      }
      list.role = role
      changed = true
    }
    if changed { try modelContext.save() }
    return (changes, changed)
  }

  /// Réponse de `list_sharing` appliquée à une liste : rôle et participants. Renvoie l'ancien rôle, `nil` si la liste
  /// n'est pas sur l'appareil.
  func applySharing(_ sharing: ListSharing) throws -> ListRole? {
    let id = sharing.listId
    guard let list = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id })).first
    else { return nil }
    let previous = list.role
    list.role = sharing.role
    list.participants = sharing.members.isEmpty ? [] : sharing.participants
    if list.ownerId == nil { list.ownerId = sharing.owner.userId }
    try modelContext.save()
    return previous
  }

  /// Nom de la liste, pour le message d'un retrait.
  func listName(_ listId: UUID) throws -> String? {
    try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == listId })).first?.name
  }

  /// Écritures d'articles de cette liste encore en file : celles que `refreshAccess` va jeter.
  func pendingItemWrites(listId: UUID) throws -> Int {
    let pending = SyncState.pending.rawValue
    return try modelContext.fetch(FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.syncStateRaw == pending }))
      .filter { ($0.kind == .upsertItem || $0.kind == .deleteItem) && OutboxDependencies.listId(of: $0) == listId }
      .count
  }

  /// Listes partagées avec moi (rôle autre que propriétaire), avec leur nom et le prénom du propriétaire : leur
  /// retrait de l'appareil s'annonce.
  func listsSharedWithMe() throws -> [UUID: SharingAccessChange] {
    let owner = ListRole.owner.rawValue
    let lists = try modelContext.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.roleRaw != owner }))
    return Dictionary(
      lists.map { list in
        let ownerName = list.participants.first { $0.role == .owner }?.displayName
        return (
          list.id, SharingAccessChange(listId: list.id, listName: list.name, ownerName: ownerName, kind: .removed)
        )
      }
    ) { first, _ in first }
  }
}
