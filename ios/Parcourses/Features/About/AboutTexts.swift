import Foundation

/// Pages publiques de confidentialité (#87, lot 87.8), exigées par la règle 5.1.1(i) de l'App Review. L'adresse est
/// fixe : elle ne dépend ni du serveur ni de l'hôte des invitations, et reste lisible dans un build sans Supabase.
nonisolated enum PrivacyLinks {
  static let policy = URL(string: "https://parcourses.hadrien.eu/confidentialite/")
}

/// Textes de l'écran À propos et de la suppression des données qui dépendent du compte, communs à iOS et Android
/// (#68 §5.2, §5.7, #87 lot 87.8). Un compte e-mail n'est jamais purgé pour inactivité : seuls les textes d'un compte
/// anonyme parlent des 365 jours.
nonisolated enum AboutTexts {
  /// Dernière phrase de la section Confidentialité, quand la suppression touche aussi nos serveurs.
  static func retention(isEmailAccount: Bool) -> String {
    let removal = "Vous pouvez supprimer ces données à tout moment ci-dessous."
    return isEmailAccount
      ? removal
      : removal + " Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
  }

  /// Ce que la personne efface : son identifiant anonyme, ou son compte e-mail.
  static func accountWords(isEmailAccount: Bool) -> String {
    isEmailAccount ? "votre compte (adresse e-mail et prénom)" : "votre identifiant anonyme"
  }

  /// Section « Vos données ».
  static func yourData(deletesServerData: Bool, isEmailAccount: Bool) -> String {
    deletesServerData
      ? "Vous pouvez effacer vos listes, vos visites et \(accountWords(isEmailAccount: isEmailAccount)), sur cet appareil et sur nos serveurs."
      : "Vous pouvez effacer vos listes et vos visites de cet appareil."
  }

  /// Message de « Supprimer toutes vos données ? ». Une liste partagée passe à l'un de ses membres (lot 87.8).
  static func confirmation(deletesServerData: Bool, isEmailAccount: Bool, interruptsShopping: Bool) -> String {
    var sentences =
      deletesServerData
      ? [
        "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que \(accountWords(isEmailAccount: isEmailAccount)).",
        "Une liste que vous partagez avec d'autres passe à l'un de ses membres.",
        "Votre contribution anonyme au plan des rayons des magasins est conservée.",
        "C'est définitif.",
      ]
      : ["Vos listes et vos visites seront effacées de cet appareil."]
    if interruptsShopping { sentences.append("Vos courses en cours seront interrompues.") }
    return sentences.joined(separator: " ")
  }

  /// Message sous « Vos données ont été supprimées de cet appareil. » : le compte serveur était hors d'atteinte. Seul un
  /// compte anonyme y sera purgé après 365 jours.
  static func deletedFromDeviceMessage(isEmailAccount: Bool) -> String? {
    isEmailAccount ? nil : "Celles de nos serveurs seront supprimées après 365 jours sans utilisation."
  }
}
