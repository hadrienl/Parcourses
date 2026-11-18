import Foundation

/// Compte de revue des stores (#149) : les relecteurs d'Apple et de Google se connectent sans boîte mail. Pour cette
/// adresse, l'app n'envoie aucun code ; le code fixe saisi est vérifié par l'Edge Function `review-sign-in`, qui rend
/// une session du compte de revue. Même règle sur Android.
///
/// L'adresse exacte n'est pas dans l'app : `revue-` suivi d'un suffixe aléatoire, choisi au réglage du serveur et
/// connu seulement des consoles des stores. Quelqu'un qui lit le binaire ne peut donc pas épuiser les plafonds
/// d'essais, qui ne comptent que l'adresse réglée. Le domaine est à nous : personne d'autre n'y reçoit de code.
nonisolated enum ReviewAccount {
  /// `normalizedEmail` : adresse déjà normalisée (`AccountLink.normalize(email:)`, sans espace, en minuscules).
  static func matches(_ normalizedEmail: String) -> Bool {
    normalizedEmail.wholeMatch(of: /revue-[a-z0-9]{6,32}@parcourses\.hadrien\.eu/) != nil
  }
}
