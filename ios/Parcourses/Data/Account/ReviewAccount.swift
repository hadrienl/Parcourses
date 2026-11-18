import Foundation

/// Compte de revue des stores (#149) : les relecteurs d'Apple et de Google se connectent sans boîte mail. Pour cette
/// adresse, l'app n'envoie aucun code ; le code fixe saisi est vérifié par l'Edge Function `review-sign-in`, qui rend
/// une session du compte de revue. Même constante sur Android.
nonisolated enum ReviewAccount {
  /// Adresse du compte de revue, sur un domaine à nous : personne d'autre n'y reçoit de code.
  static let email = "revue@parcourses.hadrien.eu"

  /// `normalizedEmail` : adresse déjà normalisée (`AccountLink.normalize(email:)`, sans espace, en minuscules).
  static func matches(_ normalizedEmail: String) -> Bool {
    normalizedEmail == email
  }
}
