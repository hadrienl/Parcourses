import Foundation
import Observation

/// Une invitation reçue, telle que sa carte l'affiche (#87 §9.5) : retrouvée par mon adresse (`my_invitations`) ou
/// ouverte par son lien (`preview_invitation`).
@Observable
final class InvitationCardModel: Identifiable {
  enum Source: Equatable {
    case received(ReceivedInvitation)
    case link(token: String)
  }

  enum Phase: Equatable {
    case loading
    /// La carte est lisible : `state` dit laquelle.
    case ready
    case accepting
    /// Compte anonyme : les RPC le refusent, il faut se connecter d'abord (le jeton reste en mémoire).
    case signInRequired
    case offline
    /// Échec passager : « L'invitation n'a pas pu être acceptée. Réessayez dans un instant. »
    case failed
  }

  let id = UUID()
  let source: Source
  private(set) var phase: Phase
  private(set) var state: InvitationCardState = .acceptable
  private(set) var inviterName: String?
  private(set) var listName: String?
  private(set) var role: ListRole?
  private(set) var expiresAt: Date?
  private(set) var invitedEmailMasked: String?
  /// Invitation par adresse, refusable ; `nil` pour un lien vers une autre adresse.
  private(set) var invitationId: UUID?
  /// Liste déjà rejointe (déjà membre).
  private(set) var memberListId: UUID?

  @ObservationIgnored private weak var center: SharingCenter?

  init(source: Source, center: SharingCenter) {
    self.source = source
    self.center = center
    switch source {
    case .received(let invitation):
      phase = .ready
      inviterName = invitation.inviterName
      listName = invitation.listName
      role = invitation.role
      expiresAt = invitation.expiresAt
      invitationId = invitation.id
    case .link:
      phase = .loading
    }
  }

  var accountEmail: String? { center?.dependencies.accountEmail() }

  /// Titre de la carte : sans nom de liste pour une autre adresse (le serveur ne le donne pas).
  var title: String { SharingFormat.invitationTitle(inviter: inviterName, listName: listName) }

  /// « Peut modifier · expire le 21 nov. »
  func meta(abbreviated: Bool = true) -> String {
    [role.map(SharingFormat.roleLabel), expiresAt.map { SharingFormat.expiryDate($0, abbreviated: abbreviated) }]
      .compactMap(\.self).joined(separator: " · ")
  }

  /// Libellé lu de la carte (maquette, écran 5).
  var accessibilityLabel: String {
    "Invitation. \(title). \(meta(abbreviated: false))."
  }

  var inviterInitial: String { SharingDecisions.memberInitial(inviterName) }

  /// Message d'un état sans action (expirée, utilisée…).
  var message: String? {
    switch phase {
    case .signInRequired: return "Vous avez ouvert une invitation. Connectez-vous avec l'adresse qui l'a reçue."
    case .offline: return "Il faut du réseau pour accepter. L'invitation vous attend dans vos listes."
    case .failed: return "L'invitation n'a pas pu être acceptée. Réessayez dans un instant."
    case .loading, .accepting, .ready: break
    }
    switch state {
    case .acceptable, .otherAddress: return nil
    case .alreadyMember: return "Vous faites déjà partie de cette liste."
    case .used: return "Cette invitation a déjà été utilisée."
    case .expired:
      let inviter = inviterName.map { "Demandez à \($0) de vous la renvoyer." }
        ?? "Demandez à la personne qui vous l'a envoyée de vous la renvoyer."
      return "Cette invitation a expiré. \(inviter)"
    case .invalid:
      return "Cette invitation n'est plus valable. Demandez-en une nouvelle à la personne qui vous l'a envoyée."
    case .rateLimited: return "L'invitation n'a pas pu être acceptée. Réessayez dans un instant."
    }
  }

  /// Corps de l'avertissement « autre adresse ».
  var otherAddressBody: String {
    let sentTo = invitedEmailMasked.map { "Elle a été envoyée à \($0)." } ?? "Elle a été envoyée à une autre adresse."
    let account = accountEmail.map { " Votre compte\u{00A0}: \($0)." } ?? ""
    let who = SharingFormat.inviterName(inviterName)
    return "\(sentTo)\(account) Si vous acceptez, \(who) verra votre prénom parmi les membres."
  }

  /// On peut accepter : invitation valable (même avec une autre adresse, après l'avertissement, Q4).
  var canAccept: Bool { phase == .ready && (state == .acceptable || state == .otherAddress) }

  /// Refus possible : seulement une invitation à mon adresse (`decline_invitation` l'exige).
  var canDecline: Bool { canAccept && state == .acceptable && invitationId != nil }

  // MARK: - Actions

  /// Lien : aperçu par `preview_invitation`. Un compte anonyme se connecte d'abord.
  func load() async {
    guard case .link(let token) = source, let center else { return }
    guard center.isEmailAccount else {
      phase = .signInRequired
      return
    }
    guard let gateway = center.gateway else {
      phase = .failed
      return
    }
    phase = .loading
    do {
      let preview = try await gateway.previewInvitation(token: token)
      state = preview.cardState
      inviterName = preview.inviterName
      listName = preview.listName
      role = preview.role
      expiresAt = preview.expiresAt
      invitedEmailMasked = preview.invitedEmailMasked
      invitationId = preview.emailMatches ? preview.invitationId : nil
      memberListId = preview.listId
      phase = .ready
    } catch let error as SharingRequestError {
      phase = error.kind == .offline ? .offline : (error.kind == .signInRequired ? .signInRequired : .failed)
    } catch {
      phase = .failed
    }
  }

  /// Accepte, descend la liste, et renvoie son identifiant pour l'ouvrir (`nil` : rien à ouvrir, `phase` le dit).
  func accept() async -> UUID? {
    guard let center, let gateway = center.gateway, canAccept else { return nil }
    guard center.isOnline else {
      phase = .offline
      return nil
    }
    phase = .accepting
    do {
      let acceptance: InvitationAcceptance
      switch source {
      case .received(let invitation): acceptance = try await gateway.acceptInvitation(id: invitation.id)
      case .link(let token): acceptance = try await gateway.acceptInvitation(token: token)
      }
      guard acceptance.outcome.opensList, let listId = acceptance.listId else {
        state = Self.cardState(after: acceptance.outcome)
        phase = .ready
        return nil
      }
      if let invitationId { center.dropInvitation(invitationId) }
      // Accès gagné : descente complète de la liste avant de l'ouvrir (§6.4).
      await center.dependencies.synchronize()
      guard center.dependencies.listExists(listId) else {
        phase = .failed
        return nil
      }
      return listId
    } catch let error as SharingRequestError {
      phase = error.kind == .offline ? .offline : (error.kind == .signInRequired ? .signInRequired : .failed)
      return nil
    } catch {
      phase = .failed
      return nil
    }
  }

  /// Refus confirmé : l'invitation disparaît. Faux s'il n'a pas pu partir.
  func decline() async -> Bool {
    guard let center, let gateway = center.gateway, let invitationId, canDecline else { return false }
    guard center.isOnline else {
      phase = .offline
      return false
    }
    do {
      try await gateway.declineInvitation(id: invitationId)
      center.dropInvitation(invitationId)
      return true
    } catch {
      phase = .failed
      return false
    }
  }

  /// Après un message passager (hors ligne, échec), la carte redevient utilisable.
  func retry() async {
    switch source {
    case .received: phase = .ready
    case .link: await load()
    }
  }

  private static func cardState(after outcome: AcceptOutcome) -> InvitationCardState {
    switch outcome {
    case .joined, .alreadyMember: .alreadyMember
    case .used: .used
    case .expired: .expired
    case .invalid: .invalid
    case .rateLimited: .rateLimited
    }
  }
}
