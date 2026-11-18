import Foundation
import Supabase

// Preuve d'appareil (#137) : Edge Function `attest-device`, appelée comme `send-invitation` (JWT de la session et clé
// publique). Le statut et le corps sont rendus tels quels : `AttestationDecisions.responseOutcome` les lit.
extension SupabaseGateway {
  func attestationAccount() async throws -> AttestationAccount {
    try await mapped {
      // Jamais de compte créé ici ; un compte changé sans réidentification lève `accountChanged`.
      let id = try await self.resolveExistingSession()
      guard let user = self.client.auth.currentSession?.user, user.id == id else { throw RemoteError.unauthorized }
      return AttestationAccount(id: id, isAnonymous: user.isAnonymous)
    }
  }

  func attestationChallenge() async throws -> AttestationReply {
    try await attestDevice(AttestDeviceBody(step: AttestationStep.challenge.rawValue))
  }

  func verifyAttestation(challenge: String, keyId: String, attestation: String) async throws -> AttestationReply {
    try await attestDevice(
      AttestDeviceBody(
        step: AttestationStep.verify.rawValue, challenge: challenge, keyId: keyId, attestation: attestation))
  }

  private func attestDevice(_ body: AttestDeviceBody) async throws -> AttestationReply {
    try await mapped {
      _ = try await self.resolveExistingSession()
      let token = try await self.client.auth.session.accessToken
      var request = URLRequest(url: self.attestDeviceURL)
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue(self.publishableKey, forHTTPHeaderField: "apikey")
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(body)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw RemoteError.unexpected }
      // Corps illisible (page d'erreur d'une passerelle) : seul le statut parle.
      let wire = try? JSONDecoder().decode(AttestDeviceWire.self, from: data)
      return AttestationReply(
        httpStatus: http.statusCode, status: wire?.status, error: wire?.error, challenge: wire?.challenge)
    }
  }
}

/// Corps de `attest-device`. Les champs `nil` ne sont pas envoyés.
nonisolated struct AttestDeviceBody: Encodable, Sendable {
  let step: String
  var platform = "ios"
  var challenge: String?
  var keyId: String?
  var attestation: String?

  enum CodingKeys: String, CodingKey {
    case step, platform, challenge, attestation
    case keyId = "key_id"
  }
}

/// Réponse de `attest-device`, en succès comme en échec.
nonisolated struct AttestDeviceWire: Decodable, Sendable {
  let status: String?
  let error: String?
  let challenge: String?
}
