import Foundation

extension Notification.Name {
  /// Accès à une liste changé ailleurs (#87 §1.5) : rôle abaissé ou rendu, liste retirée. `object` : `SharingAccessChange`.
  static let sharingAccessDidChange = Notification.Name("app.parcourses.sharingAccessDidChange")
}

/// Changement d'accès à une liste, appris à la descente ou par `refreshAccess`, pour les messages de la maquette.
nonisolated struct SharingAccessChange: Sendable, Equatable {
  nonisolated enum Kind: Sendable, Equatable {
    /// Passé en lecture seule. `droppedChanges` : écritures en attente jetées (« Vos 2 dernières modifications… »).
    case downgraded(droppedChanges: Int)
    /// Accès en modification rendu.
    case upgraded
    /// Liste retirée de l'appareil : retrait, départ ou suppression par le propriétaire.
    case removed
  }

  let listId: UUID
  let listName: String
  /// Prénom du propriétaire, s'il est connu.
  let ownerName: String?
  let kind: Kind
}

/// Rôles et participants d'une liste, tirés de `list_members` et `profiles` (descente) ou de `list_sharing`.
nonisolated enum ListMemberships {
  /// Ce que la descente sait d'une liste : mon rôle et ses participants (propriétaire d'abord).
  nonisolated struct Resolved: Sendable, Equatable {
    let role: ListRole?
    let participants: [ListParticipant]
  }

  /// `role` nul : la liste est à un autre et je n'y figure pas (accès perdu, la réconciliation la retirera).
  /// Participants vides : liste non partagée.
  static func resolve(
    listId: UUID, ownerId: UUID, me: UUID, members: [ListMemberRow], names: [UUID: String]
  ) -> Resolved {
    let rows = members.filter { $0.listId == listId }.sorted {
      ($0.createdAt, $0.userId.uuidString) < ($1.createdAt, $1.userId.uuidString)
    }
    let role: ListRole? =
      ownerId == me ? .owner : rows.first { $0.userId == me }.map { ListRole(rawValue: $0.role) ?? .viewer }
    guard !rows.isEmpty else { return Resolved(role: role, participants: []) }
    let owner = ListParticipant(
      userId: ownerId, displayName: names[ownerId], role: .owner, isMe: ownerId == me, joinedAt: nil)
    let others = rows.map {
      ListParticipant(
        userId: $0.userId, displayName: names[$0.userId], role: ListRole(rawValue: $0.role) ?? .viewer,
        isMe: $0.userId == me, joinedAt: $0.createdAt)
    }
    return Resolved(role: role, participants: [owner] + others)
  }

  /// Message dû à un changement de rôle, `nil` si rien à dire.
  static func change(from old: ListRole, to new: ListRole) -> SharingAccessChange.Kind? {
    switch (old, new) {
    case (.editor, .viewer), (.owner, .viewer): .downgraded(droppedChanges: 0)
    case (.viewer, .editor): .upgraded
    default: nil
    }
  }
}
