import Foundation

/// Pages publiques de confidentialité (#87, lot 87.8), exigées par la règle 5.1.1(i) de l'App Review. L'adresse est
/// fixe : elle ne dépend ni du serveur ni de l'hôte des invitations, et reste lisible dans un build sans Supabase.
nonisolated enum PrivacyLinks {
  static let policy = URL(string: "https://parcourses.hadrien.eu/confidentialite/")
  /// Demande écrite de suppression d'un compte e-mail (#122) : même adresse et même objet que `/supprimer-mes-donnees/`.
  static let deletionRequest = URL(string: "mailto:parcourses@hadrien.eu?subject=Supprimer%20mes%20donn%C3%A9es")
}

/// Textes de l'écran À propos qui dépendent du compte, communs à iOS et Android (#68 §5.2, #108, #87 lot 87.8, #122).
/// Sans utilisation de l'app, nos serveurs suppriment un compte anonyme après 365 jours, un compte e-mail après 3 ans,
/// prévenu par e-mail au moins 30 jours avant (#118). Les textes de la suppression elle-même sont dans
/// `AccountDeletionTexts`, partagés par À propos et Compte.
nonisolated enum AboutTexts {
  /// Dernière phrase de la section Confidentialité, quand la suppression touche aussi nos serveurs. Un compte anonyme
  /// supprime ses données plus bas dans À propos ; un compte e-mail, depuis l'écran Compte (#108).
  static func retention(isEmailAccount: Bool) -> String {
    isEmailAccount
      ? "Vous pouvez supprimer ces données à tout moment depuis l'écran Compte. Sur nos serveurs, elles sont aussi supprimées après 3 ans sans utilisation de l'app ; un e-mail vous prévient au moins 30 jours avant."
      : "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
  }
}
