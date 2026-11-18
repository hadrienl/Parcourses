import Foundation

// Compte de revue des stores (#149) : Edge Function `review-sign-in` (`verify_jwt = false`), appelée avec la seule clé
// publique, jamais avec le jeton de la session. Elle échange l'adresse et le code fixe contre une session du compte de
// revue, que `verifyCode` installe. Tout refus est uniforme : `400 invalid_code`.
extension SupabaseGateway {
  /// Délai de la requête : la vérification entière est déjà bornée par `AccountLink.timeout`.
  static let reviewSignInTimeout: TimeInterval = 15

  /// Session accordée, pas encore installée. Lève `AuthRequestError` sur un refus, `URLError` sur un échec réseau.
  func reviewSignIn(email: String, code: String) async throws -> ReviewSession {
    let request = try Self.reviewSignInRequest(
      url: reviewSignInURL, publishableKey: publishableKey, email: email, code: code)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RemoteError.unexpected }
    return try Self.reviewSession(status: http.statusCode, body: data)
  }

  /// Requête de `review-sign-in` : clé publique, sans en-tête `Authorization`.
  static func reviewSignInRequest(url: URL, publishableKey: String, email: String, code: String) throws -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = reviewSignInTimeout
    request.setValue(publishableKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ReviewSignInBody(email: email, code: code))
    return request
  }

  /// Réponse de `review-sign-in`. Hors 2xx : `AuthRequestError` avec le statut et le champ `error` (absent d'un corps
  /// illisible), que `AccountLink` classe comme un code refusé de GoTrue.
  static func reviewSession(status: Int, body: Data) throws -> ReviewSession {
    guard (200..<300).contains(status) else {
      let refusal = try? JSONDecoder().decode(ReviewSignInRefusal.self, from: body)
      throw AuthRequestError(status: status, code: refusal?.error)
    }
    return try JSONDecoder().decode(ReviewSession.self, from: body)
  }
}

/// Corps de `review-sign-in`.
nonisolated struct ReviewSignInBody: Encodable, Sendable {
  let email: String
  let code: String
}

/// Session rendue par `review-sign-in` : seuls les jetons servent, `setSession` relit le reste.
nonisolated struct ReviewSession: Decodable, Sendable, Equatable {
  let accessToken: String
  let refreshToken: String

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
  }
}

/// Refus de `review-sign-in` : `{"error": "invalid_code"}`, `invalid_body` ou `internal`.
nonisolated struct ReviewSignInRefusal: Decodable, Sendable {
  let error: String?
}
