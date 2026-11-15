import Foundation

/// Textes du partage, tirés du dictionnaire `fr` de `design/sharing-v1.html`. Aucun accord n'est déduit d'un prénom, et
/// jamais de « de + prénom » (élision impossible à garantir).
enum SharingFormat {
  private static let locale = Locale(identifier: "fr_FR")

  static func roleLabel(_ role: ListRole) -> String {
    switch role {
    case .owner: "Propriétaire"
    case .editor: "Peut modifier"
    case .viewer: "Lecture seule"
    }
  }

  /// Texte d'aide du choix de l'accès.
  static func roleHelp(_ role: ListRole) -> String {
    switch role {
    case .owner, .editor: "Ajoute, modifie et coche les articles."
    case .viewer: "Voit la liste, sans la modifier ni faire les courses."
    }
  }

  /// « il y a 2 min » : abrégé, à la française.
  static func relative(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .abbreviated
    formatter.dateTimeStyle = .numeric
    // Une heure d'appareil un peu en avance ne doit pas donner « dans 3 s ».
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }

  /// « Modifiée par Léa · il y a 2 min ».
  static func modifiedBy(_ name: String, at date: Date, now: Date) -> String {
    "Modifiée par \(name) · \(relative(date, now: now))"
  }

  /// « Modifiée par Léa, il y a 2 minutes » : la même ligne, lue par VoiceOver.
  static func modifiedByAccessibility(_ name: String, at date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .numeric
    return "Modifiée par \(name), \(formatter.localizedString(for: min(date, now), relativeTo: now))"
  }

  /// Échéance d'une invitation en attente : « expire dans 7 j », « Expirée ».
  static func pendingExpiry(_ invitation: PendingInvitation, now: Date) -> String {
    if invitation.expired || invitation.expiresAt <= now { return "Expirée" }
    let days = max(1, Int((invitation.expiresAt.timeIntervalSince(now) / 86_400).rounded(.up)))
    return "expire dans \(days)\u{00A0}j"
  }

  /// Même échéance, lue en entier.
  static func pendingExpiryAccessibility(_ invitation: PendingInvitation, now: Date) -> String {
    if invitation.expired || invitation.expiresAt <= now { return "expirée" }
    let days = max(1, Int((invitation.expiresAt.timeIntervalSince(now) / 86_400).rounded(.up)))
    return days == 1 ? "expire dans 1 jour" : "expire dans \(days) jours"
  }

  /// « expire le 21 nov. », ou la date entière (« 21 novembre ») pour les grandes tailles de texte et VoiceOver.
  static func expiryDate(_ date: Date, abbreviated: Bool = true) -> String {
    let style = Date.FormatStyle(locale: locale).day().month(abbreviated ? .abbreviated : .wide)
    return "expire le \(date.formatted(style))"
  }

  /// « Membre depuis le 12 novembre ».
  static func memberSince(_ date: Date) -> String {
    "Membre depuis le \(date.formatted(Date.FormatStyle(locale: locale).day().month(.wide)))"
  }

  /// « Hadrien vous invite à « Courses de la semaine » », ou sans le nom de la liste (autre adresse).
  static func invitationTitle(inviter: String?, listName: String?) -> String {
    let who = inviterName(inviter)
    guard let listName else { return "\(who) vous invite à une liste de courses" }
    return "\(who) vous invite à «\u{00A0}\(listName)\u{00A0}»"
  }

  static func inviterName(_ name: String?) -> String {
    let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Quelqu'un" : trimmed
  }

  /// « Demandez à Hadrien… » ou, sans prénom connu, une tournure sans destinataire.
  static func askOwner(_ ownerName: String?) -> String {
    guard let ownerName else {
      return "Lecture seule. Demandez l'accès en modification à la personne qui a partagé la liste."
    }
    return "Lecture seule. Demandez à \(ownerName) l'accès en modification."
  }

  /// Aucune invitation en attente (`inv.none`, `inv.none.body`) : l'adresse du compte, puis le conseil d'ouvrir le
  /// lien de l'e-mail, l'invitation visant peut-être une autre adresse.
  static func noInvitation(email: String?) -> (title: String, body: String) {
    (
      email.map { "Aucune invitation n'attend \($0)." } ?? "Aucune invitation en attente.",
      "Celle que vous avez reçue vise peut-être une autre adresse : ouvrez le lien de l'e-mail."
    )
  }

  /// « Hadrien a passé votre accès en lecture seule. » (`downgrade.plain`) : titre de la feuille du mode courses.
  static func downgradedTitle(ownerName: String?) -> String {
    ownerName.map { "\($0) a passé votre accès en lecture seule." } ?? "Votre accès est passé en lecture seule."
  }

  /// Bannière « accès abaissé » (maquette, écran 1).
  static func downgraded(ownerName: String?, dropped: Int) -> String {
    let who = downgradedTitle(ownerName: ownerName)
    guard dropped > 0 else { return who }
    let changes =
      dropped == 1
      ? "Votre dernière modification n'a pas été enregistrée."
      : "Vos \(dropped) dernières modifications n'ont pas été enregistrées."
    return "\(who) \(changes)"
  }

  static func upgraded(ownerName: String?) -> String {
    ownerName.map { "\($0) vous a donné l'accès en modification." } ?? "Vous avez maintenant l'accès en modification."
  }

  static func removedTitle(_ listName: String) -> String {
    "«\u{00A0}\(listName)\u{00A0}» n'est plus partagée avec vous"
  }
}
