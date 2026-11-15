import Foundation

/// Membre d'une liste (`list_members`, #87 lot 87.2), hors propriétaire. Lisible par les membres de la liste.
nonisolated struct ListMemberRow: TableDTO, Equatable {
  static let table = "list_members"
  static var columns: [String] { CodingKeys.allCases.map(\.rawValue) }

  let listId: UUID
  let userId: UUID
  /// `editor` ou `viewer`.
  let role: String
  let addedBy: UUID?
  let createdAt: Date
  let updatedAt: Date

  init(listId: UUID, userId: UUID, role: String, addedBy: UUID? = nil, createdAt: Date, updatedAt: Date) {
    self.listId = listId
    self.userId = userId
    self.role = role
    self.addedBy = addedBy
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey, CaseIterable {
    case role
    case listId = "list_id"
    case userId = "user_id"
    case addedBy = "added_by"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }
}

/// JSON renvoyé par `list_sharing` (colonnes en snake_case).
nonisolated struct ListSharingWire: Decodable, Sendable {
  nonisolated struct Owner: Decodable, Sendable {
    let userId: UUID
    let displayName: String?
    let isMe: Bool

    enum CodingKeys: String, CodingKey {
      case userId = "user_id"
      case displayName = "display_name"
      case isMe = "is_me"
    }
  }

  nonisolated struct Member: Decodable, Sendable {
    let userId: UUID
    let displayName: String?
    let role: String
    let isMe: Bool
    let joinedAt: Date?

    enum CodingKeys: String, CodingKey {
      case role
      case userId = "user_id"
      case displayName = "display_name"
      case isMe = "is_me"
      case joinedAt = "joined_at"
    }
  }

  nonisolated struct Invitation: Decodable, Sendable {
    let id: UUID
    let email: String
    let role: String
    let createdAt: Date
    let expiresAt: Date
    let sentCount: Int
    let expired: Bool

    enum CodingKeys: String, CodingKey {
      case id, email, role, expired
      case createdAt = "created_at"
      case expiresAt = "expires_at"
      case sentCount = "sent_count"
    }
  }

  let listId: UUID
  let role: String
  let owner: Owner
  let members: [Member]
  let invitations: [Invitation]

  enum CodingKeys: String, CodingKey {
    case role, owner, members, invitations
    case listId = "list_id"
  }

  /// Rôle inconnu (version future du serveur) : lecteur, le plus prudent.
  var model: ListSharing {
    ListSharing(
      listId: listId, role: ListRole(rawValue: role) ?? .viewer,
      owner: ListParticipant(
        userId: owner.userId, displayName: owner.displayName, role: .owner, isMe: owner.isMe, joinedAt: nil),
      members: members.map {
        ListParticipant(
          userId: $0.userId, displayName: $0.displayName, role: ListRole(rawValue: $0.role) ?? .viewer, isMe: $0.isMe,
          joinedAt: $0.joinedAt)
      },
      invitations: invitations.map {
        PendingInvitation(
          id: $0.id, email: $0.email, role: ListRole(rawValue: $0.role) ?? .viewer, createdAt: $0.createdAt,
          expiresAt: $0.expiresAt, sentCount: $0.sentCount, expired: $0.expired)
      })
  }
}

/// Ligne de `my_invitations`.
nonisolated struct ReceivedInvitationRow: Decodable, Sendable {
  let id: UUID
  let listId: UUID
  let listName: String
  let inviterName: String?
  let role: String
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case id, role
    case listId = "list_id"
    case listName = "list_name"
    case inviterName = "inviter_name"
    case expiresAt = "expires_at"
  }

  var model: ReceivedInvitation {
    ReceivedInvitation(
      id: id, listId: listId, listName: listName, inviterName: inviterName, role: ListRole(rawValue: role) ?? .viewer,
      expiresAt: expiresAt)
  }
}

/// Ligne de `preview_invitation`.
nonisolated struct InvitationPreviewRow: Decodable, Sendable {
  let status: String
  let invitationId: UUID?
  let listId: UUID?
  let listName: String?
  let inviterName: String?
  let role: String?
  let emailMatches: Bool?
  let invitedEmailMasked: String?
  let expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case status, role
    case invitationId = "invitation_id"
    case listId = "list_id"
    case listName = "list_name"
    case inviterName = "inviter_name"
    case emailMatches = "email_matches"
    case invitedEmailMasked = "invited_email_masked"
    case expiresAt = "expires_at"
  }

  var model: InvitationPreview {
    InvitationPreview(
      status: status, invitationId: invitationId, listId: listId, listName: listName, inviterName: inviterName,
      role: role.flatMap(ListRole.init(rawValue:)), emailMatches: emailMatches ?? false,
      invitedEmailMasked: invitedEmailMasked, expiresAt: expiresAt)
  }
}

/// Ligne de `accept_invitation`.
nonisolated struct InvitationAcceptanceRow: Decodable, Sendable {
  let status: String
  let listId: UUID?
  let role: String?

  enum CodingKeys: String, CodingKey {
    case status, role
    case listId = "list_id"
  }

  var model: InvitationAcceptance {
    InvitationAcceptance(status: status, listId: listId, role: role.flatMap(ListRole.init(rawValue:)))
  }
}

/// Ligne de `create_invitation` (« Copier le lien ») : le jeton, rendu une seule fois.
nonisolated struct CreatedInvitationRow: Decodable, Sendable {
  let invitationId: UUID
  let token: String
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case token
    case invitationId = "invitation_id"
    case expiresAt = "expires_at"
  }
}

/// Réponse 200 de `send-invitation`.
nonisolated struct SentInvitationWire: Decodable, Sendable {
  let invitationId: UUID
  let link: String
  let sent: Bool
  let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case link, sent
    case invitationId = "invitation_id"
    case expiresAt = "expires_at"
  }
}

/// Corps de `send-invitation`.
nonisolated struct SendInvitationBody: Encodable, Sendable {
  let listId: UUID
  let email: String
  let role: String

  enum CodingKeys: String, CodingKey {
    case email, role
    case listId = "list_id"
  }
}

/// Paramètres des RPC du partage.
nonisolated struct SharingRPCParameters: Encodable, Sendable {
  var listId: UUID?
  var userId: UUID?
  var email: String?
  var role: String?
  var sendEmail: Bool?
  var invitationId: UUID?
  var token: String?

  enum CodingKeys: String, CodingKey {
    case listId = "p_list_id"
    case userId = "p_user_id"
    case email = "p_email"
    case role = "p_role"
    case sendEmail = "p_send_email"
    case invitationId = "p_invitation_id"
    case token = "p_token"
  }

  // Les paramètres absents ne partent pas : PostgREST choisit la fonction par les noms reçus.
  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(listId, forKey: .listId)
    try container.encodeIfPresent(userId, forKey: .userId)
    try container.encodeIfPresent(email, forKey: .email)
    try container.encodeIfPresent(role, forKey: .role)
    try container.encodeIfPresent(sendEmail, forKey: .sendEmail)
    try container.encodeIfPresent(invitationId, forKey: .invitationId)
    try container.encodeIfPresent(token, forKey: .token)
  }
}
