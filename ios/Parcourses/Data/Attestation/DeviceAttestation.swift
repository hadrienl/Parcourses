import CryptoKit
import DeviceCheck
import Foundation
import OSLog

/// Preuve d'appareil (#137) : App Attest atteste une clé neuve, liée à un défi du serveur. Le serveur marque alors le
/// compte comme attesté, ce qui compte dans `catalog.is_established`. Rien n'est bloqué sans preuve : la tentative
/// tourne en tâche de fond, sans texte, sans attente de l'interface et sans erreur remontée. Seulement pour un compte
/// anonyme ; un compte e-mail est déjà établi, et rien n'est envoyé à Apple pour lui.
///
/// Pas d'assertion : une nouvelle clé par tentative, jamais gardée. Une même clé ne doit pas attester plusieurs comptes.
nonisolated final class DeviceAttestation: Sendable {
  private static let logger = Logger(subsystem: "app.parcourses", category: "attestation")

  private let gateway: any AttestationGateway
  private let attester: any DeviceAttester
  private let store: any AttestationStateStore
  private let clock: any AttestationClock

  init(
    gateway: any AttestationGateway, attester: any DeviceAttester = AppAttestDeviceAttester(),
    store: any AttestationStateStore = UserDefaultsAttestationStateStore(),
    clock: any AttestationClock = SystemAttestationClock()
  ) {
    self.gateway = gateway
    self.attester = attester
    self.store = store
    self.clock = clock
  }

  /// Lance la tentative en tâche de fond, de priorité basse. N'attend rien et ne lève jamais.
  func start() {
    Task.detached(priority: .background) { [self] in
      await runOnce()
    }
  }

  /// Une tentative si `shouldAttempt` le permet, puis l'état suivant persisté pour ce compte. Renvoie l'issue, `nil`
  /// si rien n'a été tenté (pas de session, compte e-mail, état définitif ou échéance future).
  @discardableResult
  func runOnce() async -> AttestationOutcome? {
    // Sans session lisible, rien n'est tenté ni écrit : la tentative attend un prochain lancement.
    guard let account = try? await gateway.attestationAccount() else { return nil }
    let state = store.state(for: account.id)
    guard AttestationDecisions.shouldAttempt(isAnonymous: account.isAnonymous, state: state, now: clock.now) else {
      return nil
    }
    let outcome = await attempt()
    Self.logger.notice("Attestation : \(outcome.rawValue, privacy: .public)")
    // Compte changé pendant la tentative (connexion, suppression) : l'issue ne lui appartient pas, rien n'est écrit.
    guard let current = try? await gateway.attestationAccount(), current.id == account.id else { return outcome }
    store.save(AttestationDecisions.nextState(outcome: outcome, now: clock.now), for: account.id)
    return outcome
  }

  /// Défi, clé neuve attestée par Apple, puis vérification par le serveur.
  private func attempt() async -> AttestationOutcome {
    // Simulateur, ou appareil sans Secure Enclave : définitif, sans appel au serveur.
    guard attester.isSupported else { return .unsupported }
    let offered = await reply { try await self.gateway.attestationChallenge() }
    switch Self.response(.challenge, offered) {
    case .outcome(let outcome): return outcome
    case .proceed: break
    }
    guard let challenge = offered.challenge, !challenge.isEmpty else { return .transient }
    let keyId: String
    let attestation: Data
    do {
      keyId = try await attester.generateKey()
      attestation = try await attester.attestKey(keyId, clientDataHash: Self.clientDataHash(challenge: challenge))
    } catch {
      return Self.outcome(for: error)
    }
    let verified = await reply {
      try await self.gateway.verifyAttestation(
        challenge: challenge, keyId: keyId, attestation: attestation.base64EncodedString())
    }
    switch Self.response(.verify, verified) {
    case .outcome(let outcome): return outcome
    // Un défi à la vérification : réponse incohérente, déjà classée passagère par les vecteurs.
    case .proceed: return .transient
    }
  }

  /// Une requête sans réponse devient le statut 0 des vecteurs.
  private func reply(_ call: () async throws -> AttestationReply) async -> AttestationReply {
    do {
      return try await call()
    } catch {
      return AttestationReply(httpStatus: 0)
    }
  }

  private static func response(_ step: AttestationStep, _ reply: AttestationReply) -> AttestationResponse {
    AttestationDecisions.responseOutcome(
      step: step, httpStatus: reply.httpStatus, status: reply.status, error: reply.error)
  }

  /// `SHA-256` de l'UTF-8 du défi : le serveur fait le même calcul (contrat `shared/test-vectors/attestation/`).
  static func clientDataHash(challenge: String) -> Data {
    Data(SHA256.hash(data: Data(challenge.utf8)))
  }

  /// Erreurs d'App Attest : `featureUnsupported` est définitif. Le reste (`serverUnavailable`, `invalidKey`,
  /// `invalidInput`, `unknownSystemFailure`, ou une erreur inconnue) est passager : une clé neuve sera essayée.
  static func outcome(for error: any Error) -> AttestationOutcome {
    if let error = error as? DCError, error.code == .featureUnsupported { return .unsupported }
    return .transient
  }
}

// MARK: - Dépendances

/// Service d'attestation du système. `AppAttestDeviceAttester` en est l'implémentation ; les tests le simulent.
nonisolated protocol DeviceAttester: Sendable {
  var isSupported: Bool { get }
  /// Identifiant de la clé neuve, en base64 standard.
  func generateKey() async throws -> String
  /// Objet d'attestation (CBOR) de la clé, lié à `clientDataHash`.
  func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// `DCAppAttestService`. Sans l'entitlement `appattest-environment`, le système prend l'environnement de
/// développement pour un build de développement, la production sur TestFlight et l'App Store.
nonisolated struct AppAttestDeviceAttester: DeviceAttester {
  var isSupported: Bool { DCAppAttestService.shared.isSupported }

  func generateKey() async throws -> String {
    try await DCAppAttestService.shared.generateKey()
  }

  func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
    try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
  }
}

/// Heure des décisions, remplaçable dans les tests.
nonisolated protocol AttestationClock: Sendable {
  var now: Date { get }
}

nonisolated struct SystemAttestationClock: AttestationClock {
  var now: Date { .now }
}

/// État de l'attestation, par id de compte.
nonisolated protocol AttestationStateStore: Sendable {
  /// `nil` si rien n'est connu pour ce compte : celui d'un autre compte n'est jamais rendu.
  func state(for accountId: UUID) -> AttestationState?
  func save(_ state: AttestationState, for accountId: UUID)
}

/// Dans `UserDefaults.standard`, une seule entrée : l'état du dernier compte tenté, avec son id. Un autre compte n'en
/// hérite pas. Effacée par `LocalDataPurge` (« Supprimer mes données », changement de compte).
nonisolated struct UserDefaultsAttestationStateStore: AttestationStateStore, @unchecked Sendable {
  static let key = "attestation.state"

  private nonisolated struct Entry: Codable {
    let accountId: UUID
    let state: AttestationState
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func state(for accountId: UUID) -> AttestationState? {
    guard let data = defaults.data(forKey: Self.key),
      let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.accountId == accountId
    else { return nil }
    return entry.state
  }

  func save(_ state: AttestationState, for accountId: UUID) {
    guard let data = try? JSONEncoder().encode(Entry(accountId: accountId, state: state)) else { return }
    defaults.set(data, forKey: Self.key)
  }

  func clear() {
    defaults.removeObject(forKey: Self.key)
  }
}
