import Foundation

/// Participant d'une liste (#87) : le propriétaire ou un membre. Prénom seulement, jamais l'adresse. Gardé aussi sur
/// l'appareil (`ShoppingList.participants`) pour les pastilles et les marques d'auteur hors ligne.
nonisolated struct ListParticipant: Codable, Sendable, Equatable, Identifiable {
  let userId: UUID
  let displayName: String?
  let role: ListRole
  let isMe: Bool
  /// Arrivée dans la liste ; `nil` pour le propriétaire.
  let joinedAt: Date?

  var id: UUID { userId }

  /// Initiale de la pastille (vecteur `007`).
  var initial: String { SharingDecisions.memberInitial(displayName) }

  /// Prénom affiché, « Quelqu'un » sans prénom (le serveur n'en garde que pour les comptes e-mail).
  var name: String {
    let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Quelqu'un" : trimmed
  }
}

/// Invitation vivante, vue par le propriétaire dans la feuille « Partager ».
nonisolated struct PendingInvitation: Sendable, Equatable, Identifiable {
  let id: UUID
  /// Adresse saisie par le propriétaire, seul à la voir.
  let email: String
  let role: ListRole
  let createdAt: Date
  let expiresAt: Date
  let sentCount: Int
  let expired: Bool
}

/// Réponse de `list_sharing` : mon rôle, le propriétaire, les membres et, pour le propriétaire, les invitations.
nonisolated struct ListSharing: Sendable, Equatable {
  let listId: UUID
  let role: ListRole
  let owner: ListParticipant
  let members: [ListParticipant]
  let invitations: [PendingInvitation]

  /// Propriétaire puis membres, dans l'ordre d'arrivée.
  var participants: [ListParticipant] { [owner] + members }
}

/// Invitation adressée à mon adresse confirmée (`my_invitations`).
nonisolated struct ReceivedInvitation: Sendable, Equatable, Identifiable {
  let id: UUID
  let listId: UUID
  let listName: String
  let inviterName: String?
  let role: ListRole
  let expiresAt: Date
}

/// Ce que montre la carte d'une invitation ouverte par son lien (`preview_invitation`).
nonisolated struct InvitationPreview: Sendable, Equatable {
  /// `pending`, `expired`, `used`, `member`, `invalid`, `rate_limited`.
  let status: String
  let invitationId: UUID?
  let listId: UUID?
  /// Seulement si l'adresse du compte est celle de l'invitation, ou si l'on est déjà membre.
  let listName: String?
  let inviterName: String?
  let role: ListRole?
  let emailMatches: Bool
  let invitedEmailMasked: String?
  let expiresAt: Date?

  var cardState: InvitationCardState {
    SharingDecisions.invitationCardState(status: status, emailMatches: emailMatches)
  }
}

/// Réponse de l'Edge Function `send-invitation`. `sent` faux : l'invitation existe, mais l'e-mail n'est pas parti.
nonisolated struct SentInvitation: Sendable, Equatable {
  let invitationId: UUID
  let link: String
  let sent: Bool
  let expiresAt: Date
}

/// Refus d'une action de partage : l'erreur du serveur telle que les vecteurs `003` la lisent (`error` de la fonction
/// ou message de la RPC), `nil` sans réponse.
nonisolated struct SharingRequestError: Error, Sendable, Equatable {
  let error: String?

  var kind: InviteErrorKind { SharingDecisions.inviteErrorKind(error) }
}

/// Signal temps réel reçu sur `user:<uid>` (#87 §6.2) : jamais de libellé.
nonisolated struct RealtimeSignal: Sendable, Equatable {
  let listId: UUID?
  let kind: String
}
