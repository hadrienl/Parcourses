import Foundation

/// État persisté de l'attestation d'un compte (#137) : `pending` jusqu'à `nextAttemptAt`, puis `attested` ou
/// `unsupported`, définitifs. Mêmes valeurs sur Android.
nonisolated enum AttestationStatus: String, Codable, Sendable, CaseIterable {
  case pending
  case attested
  case unsupported
}

/// État d'un compte, persisté par id de compte (`AttestationStateStore`). Aucun état : première tentative.
nonisolated struct AttestationState: Codable, Sendable, Equatable {
  let status: AttestationStatus
  /// Prochaine tentative possible ; `nil` pour un état définitif.
  let nextAttemptAt: Date?
}

/// Issue d'une tentative (vecteurs `002` et `003`). Mêmes noms sur Android.
nonisolated enum AttestationOutcome: String, Sendable, Equatable, CaseIterable {
  case attested
  case unsupported
  /// Réseau, 5xx, 401, 429, erreur passagère d'Apple : nouvel essai au plus tôt 1 h après.
  case transient
  /// Secrets absents sur le serveur : 24 h.
  case notConfigured
  /// Preuve refusée, défi invalide, corps refusé : 7 jours.
  case rejected
}

/// Appel de l'Edge Function `attest-device`.
nonisolated enum AttestationStep: String, Sendable, Equatable {
  case challenge
  case verify
}

/// Suite d'une réponse de `attest-device` (vecteur `003`) : passer à la preuve, ou terminer la tentative.
nonisolated enum AttestationResponse: Sendable, Equatable {
  /// Défi reçu : générer la preuve. Seulement à l'étape `challenge`.
  case proceed
  case outcome(AttestationOutcome)
}

/// Décisions pures de l'attestation d'appareil, communes avec Android (`shared/test-vectors/attestation/`).
nonisolated enum AttestationDecisions {
  static let transientDelay: TimeInterval = 3600
  static let notConfiguredDelay: TimeInterval = 24 * 3600
  static let rejectedDelay: TimeInterval = 7 * 24 * 3600

  /// Vecteur `001` : seulement un compte anonyme (un compte e-mail est déjà établi, rien ne part chez Apple), sans
  /// état définitif, une fois l'échéance atteinte.
  static func shouldAttempt(isAnonymous: Bool, state: AttestationState?, now: Date) -> Bool {
    guard isAnonymous else { return false }
    guard let state else { return true }
    switch state.status {
    case .attested, .unsupported: return false
    case .pending: return (state.nextAttemptAt ?? .distantPast) <= now
    }
  }

  /// Vecteur `002` : état à persister après une tentative.
  static func nextState(outcome: AttestationOutcome, now: Date) -> AttestationState {
    switch outcome {
    case .attested: AttestationState(status: .attested, nextAttemptAt: nil)
    case .unsupported: AttestationState(status: .unsupported, nextAttemptAt: nil)
    case .transient: AttestationState(status: .pending, nextAttemptAt: now.addingTimeInterval(transientDelay))
    case .notConfigured:
      AttestationState(status: .pending, nextAttemptAt: now.addingTimeInterval(notConfiguredDelay))
    case .rejected: AttestationState(status: .pending, nextAttemptAt: now.addingTimeInterval(rejectedDelay))
    }
  }

  /// Vecteur `003`. `httpStatus` 0 : pas de réponse. `status` et `error` : champs du corps JSON, `nil` s'ils manquent.
  /// Un 400 est un refus du serveur (défi invalide, preuve refusée, corps refusé) ; tout autre échec est passager.
  static func responseOutcome(step: AttestationStep, httpStatus: Int, status: String?, error: String?)
    -> AttestationResponse
  {
    if (200..<300).contains(httpStatus) {
      switch status {
      case "challenge" where step == .challenge: return .proceed
      case "attested": return .outcome(.attested)
      case "not_configured": return .outcome(.notConfigured)
      default: return .outcome(.transient)
      }
    }
    return .outcome(httpStatus == 400 ? .rejected : .transient)
  }
}
