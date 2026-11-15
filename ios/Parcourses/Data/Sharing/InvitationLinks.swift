import Foundation

/// Liens d'invitation (#87 §5). L'hôte https vient de la configuration de build (clé `ParcoursesInvitationHost` de
/// l'Info.plist, réglage `PARCOURSES_INVITATION_HOST` des xcconfig, `parcourses.hadrien.eu` par défaut depuis le lot
/// 87.7) ; le même réglage donne le domaine associé `applinks:` des liens universels. Hôte vide : aucun lien https
/// construit ni reconnu, seul le schéma `parcourses://` reste. Aucun domaine n'est écrit dans le code.
nonisolated struct InvitationLinks: Sendable, Equatable {
  static let infoKey = "ParcoursesInvitationHost"

  /// `nil` : pas de domaine, liens par le schéma de l'app.
  let httpsHost: String?

  init(httpsHost: String?) {
    let trimmed = httpsHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.httpsHost = trimmed.isEmpty ? nil : trimmed
  }

  init(bundle: Bundle = .main) {
    self.init(httpsHost: bundle.object(forInfoDictionaryKey: Self.infoKey) as? String)
  }

  /// Lien construit par l'app (« Copier le lien ») : `https://<hôte>/i/#<jeton>`, sinon le schéma de l'app.
  func link(token: String) -> String {
    guard let httpsHost else { return "\(SharingDecisions.schemeBase)#\(token)" }
    return "https://\(httpsHost)/i/#\(token)"
  }

  /// Jeton d'un lien ouvert dans l'app (vecteur `001`), `nil` pour tout autre lien.
  func token(in url: URL) -> String? {
    SharingDecisions.parseInvitationLink(url: url.absoluteString, httpsHost: httpsHost)
  }
}
