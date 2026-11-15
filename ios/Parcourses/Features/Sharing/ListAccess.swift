import Foundation

/// Accès à une liste tel que l'écran le montre (#87 §9) : mon rôle, les participants, et ce qui en découle.
struct ListAccess: Equatable {
  var role: ListRole = .owner
  /// Propriétaire puis membres ; vide pour une liste qui n'est pas partagée.
  var participants: [ListParticipant] = []
  /// Mon compte, s'il est connu : sans lui, aucune marque d'auteur.
  var me: UUID?

  init(role: ListRole = .owner, participants: [ListParticipant] = [], me: UUID? = nil) {
    self.role = role
    self.participants = participants
    self.me = me
  }

  init(list: ShoppingList, me: UUID?) {
    self.init(role: list.role, participants: list.participants, me: me)
  }

  var capabilities: RoleCapabilities { SharingDecisions.roleCapabilities(role) }
  var isReadOnly: Bool { !capabilities.canEditItems }

  /// Partagée : au moins un autre participant que moi.
  var isShared: Bool { participants.contains { !$0.isMe } }

  /// Les autres participants : les pastilles ne me montrent jamais.
  var others: [ListParticipant] { participants.filter { !$0.isMe } }

  var owner: ListParticipant? { participants.first { $0.role == .owner } }

  /// Prénom du propriétaire, dans « Demandez à Hadrien… » ; `nil` s'il est inconnu.
  var ownerName: String? { owner.map(\.name) }

  /// Initiale de l'auteur d'un article (vecteur `008`).
  func authorMark(updatedBy: UUID?) -> String? {
    guard let me else { return nil }
    return SharingDecisions.itemAuthorMark(
      updatedBy: updatedBy, me: me, shared: isShared,
      members: participants.map { AuthorCandidate(userId: $0.userId, displayName: $0.displayName) })
  }

  /// Prénom d'un autre participant, pour « Modifiée par Léa » et « dernière modification par Léa ».
  func otherName(_ userId: UUID?) -> String? {
    guard let userId, userId != me else { return nil }
    return participants.first { $0.userId == userId && !$0.isMe }?.name
  }

  /// Pastilles des autres membres : une lettre, deux si deux membres partagent l'initiale, « +N » au-delà de trois.
  var pillLabels: [String] { Self.pillLabels(names: others.map(\.displayName)) }

  static func pillLabels(names: [String?]) -> [String] {
    let initials = names.map { SharingDecisions.memberInitial($0) }
    let labels = zip(names, initials).map { name, initial -> String in
      guard initials.filter({ $0 == initial }).count > 1 else { return initial }
      let letters = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard letters.count >= 2 else { return initial }
      return initial + String(letters.dropFirst().prefix(1)).lowercased(with: Locale(identifier: "fr_FR"))
    }
    guard labels.count > maxPills else { return labels }
    return Array(labels.prefix(maxPills)) + ["+\(labels.count - maxPills)"]
  }

  static let maxPills = 3

  /// « Léa, Tom et vous » : les autres, puis moi.
  var membersSentence: String {
    Self.sentence(others.map(\.name) + (participants.contains { $0.isMe } ? ["vous"] : []))
  }

  /// Libellé lu du bouton des pastilles (maquette, écran 1).
  var membersButtonLabel: String {
    let action = capabilities.canShare ? "Partager la liste" : "Voir les membres"
    return "Membres : \(membersSentence). \(action)"
  }

  /// Énumération à la française : « A », « A et B », « A, B et C ».
  static func sentence(_ parts: [String]) -> String {
    guard let last = parts.last else { return "" }
    guard parts.count > 1 else { return last }
    return parts.dropLast().joined(separator: ", ") + " et " + last
  }
}
