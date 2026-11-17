import Foundation

/// Opération dont la purge locale a échoué (#129). Code public commun à iOS et Android.
nonisolated enum PurgeOperation: String, CaseIterable, Sendable {
  /// Déconnexion, « Continuer sans compte » compris, et sa reprise au lancement.
  case signOut = "signout"
  /// Rejeu d'un changement de compte (drapeau `account.switch`).
  case `switch` = "switch"
}

/// Première étape en échec d'une purge (#129). Code public commun à iOS et Android.
nonisolated enum PurgeStep: String, CaseIterable, Sendable {
  /// Base locale (SwiftData).
  case store
  /// Référentiel des catégories, amorcé à nouveau.
  case categories
  /// Keychain ou session : lecture de la session, vidage du Keychain, `acknowledgeAccount`.
  case session
  /// Préférences (`UserDefaults`, cache des réponses).
  case preferences
  case unknown

  init(_ step: LocalDataPurge.Step) {
    switch step {
    case .storePurged: self = .store
    case .categoriesSeeded: self = .categories
    case .keychainPurged: self = .session
    case .preferencesPurged: self = .preferences
    }
  }

  /// Étape d'après l'erreur levée par la purge ou par l'adoption du compte. Toute autre erreur : `unknown`.
  init(of error: any Error) {
    switch error {
    case let failure as LocalDataPurge.Failure: self.init(failure.step)
    case is PurgeSessionFailure: self = .session
    default: self = .unknown
    }
  }
}

/// Lecture de la session ou `acknowledgeAccount` en échec pendant le rejeu d'un changement de compte : étape `session`.
/// L'erreur d'origine n'est journalisée qu'en privé.
nonisolated struct PurgeSessionFailure: Error {
  let underlying: any Error
}

/// Purge en échec, telle qu'on peut la montrer et la journaliser : ni adresse, ni identifiant de compte, ni texte
/// d'erreur système (#129).
nonisolated struct PurgeFailure: Equatable, Sendable {
  /// Adresse de contact, la même que pour les demandes de suppression (`PrivacyLinks.deletionRequest`).
  static let supportAddress = "parcourses@hadrien.eu"

  /// Seuls les caractères non réservés de la RFC 3986 restent en clair dans l'objet du mail.
  private static let unreserved = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

  let operation: PurgeOperation
  let step: PurgeStep

  /// `purge-<opération>-<étape>`, par exemple `purge-signout-store`.
  var publicCode: String { "purge-\(operation.rawValue)-\(step.rawValue)" }

  /// Objet du mail « Nous écrire ».
  var supportSubject: String { "Parcourses : purge impossible (\(publicCode))" }

  /// `mailto:` avec un objet et sans corps.
  var supportMailto: URL {
    let subject = supportSubject.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? publicCode
    // Toujours valide : adresse fixe, objet réduit à des caractères non réservés et à des séquences `%XX`.
    guard let url = URL(string: "mailto:\(Self.supportAddress)?subject=\(subject)") else {
      preconditionFailure("mailto invalide : \(publicCode)")
    }
    return url
  }
}
