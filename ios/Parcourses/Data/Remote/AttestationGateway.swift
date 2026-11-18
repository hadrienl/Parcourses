import Foundation

/// Compte de la session, tel que l'attestation le voit (#137).
nonisolated struct AttestationAccount: Sendable, Equatable {
  let id: UUID
  let isAnonymous: Bool
}

/// Réponse brute de l'Edge Function `attest-device`, lue ensuite par `AttestationDecisions.responseOutcome`.
nonisolated struct AttestationReply: Sendable, Equatable {
  /// Statut HTTP de la réponse.
  let httpStatus: Int
  /// `challenge`, `attested`, `not_configured` ; `nil` s'il manque ou si le corps est illisible.
  let status: String?
  /// `invalid_challenge`, `rejected`, `invalid_body`, `upstream_unavailable`… ; `nil` s'il manque.
  let error: String?
  /// Défi à signer, avec `status = challenge`.
  let challenge: String?

  init(httpStatus: Int, status: String? = nil, error: String? = nil, challenge: String? = nil) {
    self.httpStatus = httpStatus
    self.status = status
    self.error = error
    self.challenge = challenge
  }
}

/// Accès distant de la preuve d'appareil (#137), avec le JWT de la session. Jamais de compte créé. Une requête restée
/// sans réponse (réseau, session absente ou refusée au rafraîchissement) lève : c'est un échec passager.
nonisolated protocol AttestationGateway: Sendable {
  /// Compte de la session, s'il est le dernier compte connu. Lève sans session (`unauthorized`) ou si le compte a
  /// changé sans réidentification des données (`accountChanged`).
  func attestationAccount() async throws -> AttestationAccount
  /// `POST {step: "challenge", platform: "ios"}`.
  func attestationChallenge() async throws -> AttestationReply
  /// `POST {step: "verify", platform: "ios", challenge, key_id, attestation}`. `keyId` tel que rendu par
  /// `generateKey()`, `attestation` en base64 standard.
  func verifyAttestation(challenge: String, keyId: String, attestation: String) async throws -> AttestationReply
}
