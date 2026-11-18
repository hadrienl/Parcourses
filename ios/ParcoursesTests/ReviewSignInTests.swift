import Foundation
import Testing

@testable import Parcourses

/// Adresse de revue d'exemple : la vraie n'est que dans la base et les consoles des stores.
private let reviewAddress = "revue-a1b2c3d4@parcourses.hadrien.eu"

/// Contrat de l'Edge Function `review-sign-in` (#149), compte de revue des stores.
struct ReviewSignInTests {
  private static let url = URL(string: "https://exemple.supabase.co/functions/v1/review-sign-in")!

  /// Clé publique seule : jamais le jeton de la session courante.
  @Test func theRequestCarriesThePublishableKeyAndNoSessionToken() throws {
    let request = try SupabaseGateway.reviewSignInRequest(
      url: Self.url, publishableKey: "cle-publique", email: reviewAddress, code: "123456")
    #expect(request.url == Self.url)
    #expect(request.httpMethod == "POST")
    #expect(request.timeoutInterval == SupabaseGateway.reviewSignInTimeout)
    #expect(request.value(forHTTPHeaderField: "apikey") == "cle-publique")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    let data = try #require(request.httpBody)
    let body = try JSONSerialization.jsonObject(with: data) as? [String: String]
    #expect(body == ["email": reviewAddress, "code": "123456"])
  }

  @Test func aGrantedSessionIsDecoded() throws {
    let body = Data(
      #"""
      {"access_token":"jeton-acces","refresh_token":"jeton-rafraichissement","expires_in":3600,
      "expires_at":1800003600,"token_type":"bearer","user_id":"8f9c2c55-0b7e-4c31-9d4e-3a6f1d0f2b11"}
      """#.utf8)
    let session = try SupabaseGateway.reviewSession(status: 200, body: body)
    #expect(
      session
        == ReviewSession(
          accessToken: "jeton-acces", refreshToken: "jeton-rafraichissement",
          userId: UUID(uuidString: "8f9c2c55-0b7e-4c31-9d4e-3a6f1d0f2b11")!))
  }

  /// Statut et `error` gardés tels quels : `AccountLink` en tire « code faux » (4xx) ou une erreur inconnue.
  @Test(
    arguments: [
      (400, #"{"error":"invalid_code"}"#, "invalid_code"), (400, #"{"error":"invalid_body"}"#, "invalid_body"),
      (405, "", nil), (500, #"{"error":"internal"}"#, "internal"), (502, "<html>", nil),
    ] as [(Int, String, String?)])
  func everyRefusalKeepsItsStatusAndError(status: Int, body: String, code: String?) {
    #expect(throws: AuthRequestError(status: status, code: code)) {
      _ = try SupabaseGateway.reviewSession(status: status, body: Data(body.utf8))
    }
  }

  @Test func anUnreadableGrantIsNotASession() {
    #expect(throws: DecodingError.self) {
      _ = try SupabaseGateway.reviewSession(status: 200, body: Data(#"{"access_token":"a"}"#.utf8))
    }
  }
}
