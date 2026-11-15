import Foundation
import Observation
import UIKit

/// Feuille « Partager la liste » du propriétaire, et « Membres » d'un membre (#87 §9.2, §9.3). Tout passe par le réseau,
/// rien en file.
@Observable
final class ShareListModel: Identifiable {
  enum LoadState: Equatable {
    case loading
    case loaded
    /// « Le partage demande une connexion. »
    case offline
    /// « Le partage n'a pas pu s'ouvrir. Réessayez dans un instant. »
    case failed
  }

  /// E-mail non parti : l'invitation existe, le lien est à envoyer soi-même.
  struct MailFailure: Equatable {
    let link: String
  }

  let id = UUID()
  let listId: UUID
  let listName: String
  private(set) var state = LoadState.loading
  private(set) var sharing: ListSharing?
  var email = ""
  var role = ListRole.editor
  private(set) var isSending = false
  /// Erreur liée au champ, lue par VoiceOver dès la validation.
  private(set) var fieldError: String?
  /// Change à chaque erreur : la vue l'annonce et rend le focus au champ.
  private(set) var errorRevision = 0
  private(set) var mailFailure: MailFailure?
  /// Message bref (capsule au-dessus du bas de la feuille).
  private(set) var toast: String?
  /// Change à chaque message : la vue l'annonce.
  private(set) var toastRevision = 0
  /// Lignes dont une action est en cours (membre ou invitation).
  private(set) var busy: Set<UUID> = []
  /// Membre qui a quitté la liste : la feuille se ferme et la liste disparaît de l'appareil.
  private(set) var didLeave = false

  @ObservationIgnored private weak var center: SharingCenter?
  @ObservationIgnored var copy: (String) -> Void = { UIPasteboard.general.string = $0 }
  @ObservationIgnored var now: () -> Date = { .now }

  init(listId: UUID, listName: String, center: SharingCenter) {
    self.listId = listId
    self.listName = listName
    self.center = center
  }

  var isOwner: Bool { sharing?.role == .owner }
  var members: [ListParticipant] { sharing?.participants ?? [] }
  var invitations: [PendingInvitation] { sharing?.invitations ?? [] }
  var ownerName: String? { sharing?.owner.name }
  /// Compte e-mail : seul à pouvoir inviter. Un anonyme passe d'abord par « Se connecter ».
  var canInvite: Bool { center?.isEmailAccount == true }
  var canSend: Bool { !isSending && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  // MARK: - Lecture

  /// `list_sharing`. Hors ligne ou en échec, la feuille le dit ; une relecture garde la dernière réponse affichée.
  func load() async {
    guard let gateway = center?.gateway else {
      state = .failed
      return
    }
    if sharing == nil { state = .loading }
    do {
      sharing = try await gateway.listSharing(listId: listId)
      state = .loaded
    } catch RemoteError.network {
      if sharing == nil { state = .offline }
    } catch {
      if sharing == nil { state = .failed }
    }
  }

  // MARK: - Invitations

  /// « Envoyer l'invitation » : la feuille reste ouverte, champ vidé, capsule « Invitation envoyée à… ».
  func send() async {
    let address = AccountLink.normalize(email: email)
    guard canSend else { return }
    guard AccountLink.isValid(email: address) else {
      fail(.invalidEmail)
      return
    }
    guard let gateway = center?.gateway, center?.isOnline != false else {
      fail(.offline)
      return
    }
    isSending = true
    defer { isSending = false }
    fieldError = nil
    mailFailure = nil
    do {
      let sent = try await gateway.sendInvitation(listId: listId, email: address, role: role)
      email = ""
      if sent.sent {
        show("Invitation envoyée à \(address)")
      } else {
        mailFailure = MailFailure(link: sent.link)
      }
      await load()
    } catch let error as SharingRequestError {
      fail(error.kind)
    } catch {
      fail(.unknown)
    }
  }

  /// « Renvoyer » : nouveau jeton et nouvelle échéance, e-mail envoyé.
  func resend(_ invitation: PendingInvitation) async {
    await perform(on: invitation.id) { gateway in
      let sent = try await gateway.sendInvitation(listId: self.listId, email: invitation.email, role: invitation.role)
      if sent.sent {
        self.show("Invitation renvoyée. Le nouveau lien est valable 7\u{00A0}jours.")
      } else {
        self.mailFailure = MailFailure(link: sent.link)
      }
    }
  }

  /// « Copier le lien » : le jeton est stocké haché, le serveur en crée un nouveau, sans e-mail.
  func copyLink(_ invitation: PendingInvitation) async {
    await perform(on: invitation.id) { gateway in
      let link = try await gateway.invitationLink(listId: self.listId, email: invitation.email, role: invitation.role)
      self.copy(link)
      self.show("Nouveau lien copié, valable 7\u{00A0}jours. Celui de l'e-mail ne fonctionne plus.")
    }
  }

  /// Lien de la carte « e-mail non parti ».
  func copyFailedMailLink() {
    guard let mailFailure else { return }
    copy(mailFailure.link)
    show("Lien copié. Il est valable 7\u{00A0}jours.")
  }

  func revoke(_ invitation: PendingInvitation) async {
    await perform(on: invitation.id) { gateway in
      try await gateway.revokeInvitation(id: invitation.id)
    }
  }

  // MARK: - Membres

  /// Effet immédiat chez le membre (§6).
  func setRole(_ member: ListParticipant, to role: ListRole) async {
    guard member.role != role else { return }
    await perform(on: member.userId, offlineMessage: "Changer les accès demande une connexion.") { gateway in
      try await gateway.setMemberRole(listId: self.listId, userId: member.userId, role: role)
      self.show(
        role == .viewer ? "\(member.name) passe en lecture seule." : "\(member.name) peut maintenant modifier la liste."
      )
    }
  }

  func remove(_ member: ListParticipant) async {
    await perform(on: member.userId, offlineMessage: "Changer les accès demande une connexion.") { gateway in
      try await gateway.removeMember(listId: self.listId, userId: member.userId)
    }
  }

  /// « Quitter la liste » : `remove_member` sur moi, puis la liste quitte l'appareil.
  func leave() async {
    guard let me = sharing?.participants.first(where: \.isMe) else { return }
    await perform(on: me.userId, offlineMessage: "Changer les accès demande une connexion.", reload: false) { gateway in
      try await gateway.removeMember(listId: self.listId, userId: me.userId)
      self.center?.dependencies.forgetList(self.listId)
      self.didLeave = true
    }
  }

  func dismissToast() {
    toast = nil
  }

  // MARK: - Outils

  private func perform(
    on id: UUID, offlineMessage: String = "Le partage demande une connexion.", reload: Bool = true,
    _ action: (any RemoteGateway) async throws -> Void
  ) async {
    guard let gateway = center?.gateway else { return }
    guard center?.isOnline != false else {
      show(offlineMessage)
      return
    }
    busy.insert(id)
    defer { busy.remove(id) }
    do {
      try await action(gateway)
    } catch let error as SharingRequestError where error.kind == .offline {
      show(offlineMessage)
    } catch {
      show("Le partage n'a pas pu s'ouvrir. Réessayez dans un instant.")
    }
    if reload { await load() }
  }

  private func show(_ message: String) {
    toast = message
    toastRevision += 1
  }

  private func fail(_ kind: InviteErrorKind) {
    fieldError = Self.message(for: kind)
    errorRevision += 1
  }

  /// Message de la maquette pour chaque refus (vecteur `003`).
  static func message(for kind: InviteErrorKind) -> String {
    switch kind {
    case .invalidEmail: "Cette adresse ne semble pas valide."
    case .selfInvitation: "C'est votre propre adresse."
    case .alreadyMember: "Cette personne fait déjà partie de la liste."
    case .listFull: "Une liste compte au plus 10 participants, invitations en attente comprises."
    case .dailyLimit: "Vous avez envoyé 20 invitations aujourd'hui. Réessayez demain."
    case .pendingLimit: "Vous avez 50 invitations en attente. Annulez-en avant d'en envoyer d'autres."
    case .recipientLimit: "Impossible d'inviter cette adresse pour le moment. Réessayez demain."
    case .offline: "Le partage demande une connexion."
    case .signInRequired: "Pour partager, liez une adresse e-mail."
    case .notAllowed, .unknown: "Le partage n'a pas pu s'ouvrir. Réessayez dans un instant."
    }
  }
}
