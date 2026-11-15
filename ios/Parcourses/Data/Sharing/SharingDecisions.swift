import Foundation

/// Rôle sur une liste (#87 §1) : propriétaire (`lists.owner_id`), éditeur ou lecteur (`list_members.role`). Mêmes
/// valeurs sur Android et sur le serveur.
nonisolated enum ListRole: String, Codable, Sendable, CaseIterable {
  case owner
  case editor
  case viewer
}

/// Ce que l'interface propose selon le rôle (vecteur `002`). Le serveur reste juge (RLS).
nonisolated struct RoleCapabilities: Sendable, Equatable {
  let canEditItems: Bool
  let canShop: Bool
  let canShare: Bool
  let canManageMembers: Bool
  let canLeave: Bool
  let canRenameList: Bool
  let canDeleteList: Bool
}

/// Message de la feuille « Partager » après un refus de `send-invitation` ou de `create_invitation` (vecteur `003`).
nonisolated enum InviteErrorKind: String, Sendable, Equatable {
  case invalidEmail
  case selfInvitation
  case alreadyMember
  case listFull
  case dailyLimit
  case pendingLimit
  case recipientLimit
  case notAllowed
  case signInRequired
  case offline
  case unknown
}

/// État de la carte d'une invitation ouverte par son lien (vecteur `004`, `preview_invitation`).
nonisolated enum InvitationCardState: String, Sendable, Equatable {
  case acceptable
  case otherAddress
  case alreadyMember
  case used
  case expired
  case invalid
  case rateLimited
}

/// Suite donnée à `accept_invitation` (vecteur `005`). `joined` et `alreadyMember` ouvrent la liste.
nonisolated enum AcceptOutcome: String, Sendable, Equatable {
  case joined
  case alreadyMember
  case used
  case expired
  case invalid
  case rateLimited

  /// La liste est désormais accessible : descente complète, puis ouverture.
  var opensList: Bool { self == .joined || self == .alreadyMember }
}

/// Action déclenchée par un signal temps réel (vecteur `006`). L'ordre des cas est l'ordre alphabétique des noms.
nonisolated enum SignalAction: String, Sendable, Equatable, Comparable {
  /// Descente (`pullAll`).
  case pull
  /// Relire `my_invitations`.
  case reloadInvitations
  /// Relire `list_sharing` de la liste, si sa feuille « Partager » est ouverte.
  case reloadSharing

  static func < (lhs: SignalAction, rhs: SignalAction) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Membre vu par `itemAuthorMark` : identifiant et prénom.
nonisolated struct AuthorCandidate: Sendable, Equatable {
  let userId: UUID
  let displayName: String?
}

/// Décisions du partage (#87, lots 87.4 et 87.6) : fonctions pures communes avec Android (`object SharingDecisions`),
/// vérifiées par les vecteurs de `shared/test-vectors/sharing/`. Référence : `shared/reference/sharing.ts`.
nonisolated enum SharingDecisions {
  /// Préfixe du schéma de l'app, seul reconnu tant qu'aucun domaine n'est configuré (Q2).
  static let schemeBase = "parcourses://invitation"
  private static let tokenLength = 43

  /// Jeton d'un lien d'invitation (vecteur `001`) : `parcourses://invitation#<jeton>`, ou `https://<hôte>/i/#<jeton>`
  /// si un hôte est configuré. Le jeton est dans le fragment : 43 caractères base64url.
  static func parseInvitationLink(url: String, httpsHost: String?) -> String? {
    guard let hash = url.firstIndex(of: "#") else { return nil }
    let base = String(url[..<hash])
    let token = String(url[url.index(after: hash)...])
    guard isToken(token) else { return nil }
    if base == schemeBase { return token }
    guard let httpsHost else { return nil }
    let prefix = "https://"
    guard base.lowercased().hasPrefix(prefix) else { return nil }
    let rest = base.dropFirst(prefix.count)
    guard let slash = rest.firstIndex(of: "/") else { return nil }
    let host = rest[..<slash]
    let path = rest[slash...]
    return host.lowercased() == httpsHost.lowercased() && path == "/i/" ? token : nil
  }

  /// Vecteur `002`.
  static func roleCapabilities(_ role: ListRole) -> RoleCapabilities {
    let owner = role == .owner
    let writer = owner || role == .editor
    return RoleCapabilities(
      canEditItems: writer, canShop: writer, canShare: owner, canManageMembers: owner, canLeave: !owner,
      canRenameList: owner, canDeleteList: owner)
  }

  /// Vecteur `003`. `error` nul : pas de réponse (hors ligne, délai).
  static func inviteErrorKind(_ error: String?) -> InviteErrorKind {
    guard let error else { return .offline }
    switch error {
    case "invalid_email": return .invalidEmail
    case "self_invitation": return .selfInvitation
    case "already_member": return .alreadyMember
    case "list_full": return .listFull
    case "daily_limit": return .dailyLimit
    case "pending_limit": return .pendingLimit
    case "recipient_limit": return .recipientLimit
    case "not allowed": return .notAllowed
    case "unauthorized": return .signInRequired
    default: return .unknown
    }
  }

  /// Vecteur `004`.
  static func invitationCardState(status: String, emailMatches: Bool) -> InvitationCardState {
    switch status {
    case "pending": emailMatches ? .acceptable : .otherAddress
    case "member": .alreadyMember
    case "used": .used
    case "expired": .expired
    case "rate_limited": .rateLimited
    default: .invalid
    }
  }

  /// Vecteur `005`.
  static func acceptOutcome(status: String) -> AcceptOutcome {
    switch status {
    case "accepted": .joined
    case "member": .alreadyMember
    case "used": .used
    case "expired": .expired
    case "rate_limited": .rateLimited
    default: .invalid
    }
  }

  /// Vecteur `006` : actions triées. Un type inconnu demande une descente.
  static func signalActions(kind: String, sharingSheetOpen: Bool) -> [SignalAction] {
    var actions: [SignalAction] = [kind == "invitations" ? .reloadInvitations : .pull]
    if (kind == "members" || kind == "invitations") && sharingSheetOpen { actions.append(.reloadSharing) }
    return actions.sorted()
  }

  /// Vecteur `007` : première lettre du prénom sans les blancs de tête, en majuscule ; « ? » sans prénom.
  static func memberInitial(_ displayName: String?) -> String {
    let trimmed = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first else { return "?" }
    return String(first).uppercased(with: Locale(identifier: "fr_FR"))
  }

  /// Vecteur `008` : initiale de l'auteur d'un article, seulement sur une liste partagée et pour un autre membre
  /// connu.
  static func itemAuthorMark(updatedBy: UUID?, me: UUID, shared: Bool, members: [AuthorCandidate]) -> String? {
    guard shared, let updatedBy, updatedBy != me else { return nil }
    guard let author = members.first(where: { $0.userId == updatedBy }) else { return nil }
    return memberInitial(author.displayName)
  }

  private static func isToken(_ text: String) -> Bool {
    text.utf8.count == tokenLength
      && text.utf8.allSatisfy { byte in
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
          || byte == 0x2D || byte == 0x5F
      }
  }
}
