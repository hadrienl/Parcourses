import Foundation

/// Pages publiques de confidentialité (#87, lot 87.8), exigées par la règle 5.1.1(i) de l'App Review. L'adresse est
/// fixe : elle ne dépend ni du serveur ni de l'hôte des invitations, et reste lisible dans un build sans Supabase.
nonisolated enum PrivacyLinks {
  static let policy = URL(string: "https://parcourses.hadrien.eu/confidentialite/")
}

/// Textes de l'écran À propos qui dépendent du compte, communs à iOS et Android (#68 §5.2, #108, #87 lot 87.8). Un
/// compte e-mail n'est jamais purgé pour inactivité : seuls les textes d'un compte anonyme parlent des 365 jours. Les
/// textes de la suppression elle-même sont dans `AccountDeletionTexts`, partagés par À propos et Compte.
nonisolated enum AboutTexts {
  /// Dernière phrase de la section Confidentialité, quand la suppression touche aussi nos serveurs. Un compte anonyme
  /// supprime ses données plus bas dans À propos ; un compte e-mail, depuis l'écran Compte (#108).
  static func retention(isEmailAccount: Bool) -> String {
    isEmailAccount
      ? "Vous pouvez supprimer ces données à tout moment depuis l'écran Compte."
      : "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
  }
}
