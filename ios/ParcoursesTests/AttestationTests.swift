import DeviceCheck
import Foundation
import Testing

@testable import Parcourses

private final class AttestationVectorBundleToken {}

/// Fichier de `shared/test-vectors/attestation/`, copié dans le bundle de test.
nonisolated struct AttestationVectorFile: Sendable, CustomTestStringConvertible {
  let name: String
  let data: Data

  var testDescription: String { name }

  static let all: [AttestationVectorFile] = {
    guard
      let directory = Bundle(for: AttestationVectorBundleToken.self).url(
        forResource: "attestation", withExtension: nil),
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        (try? Data(contentsOf: url)).map { AttestationVectorFile(name: url.lastPathComponent, data: $0) }
      }
  }()
}

/// `AttestationDecisions` contre les vecteurs communs avec Android (#137). Un fichier dont la fonction est inconnue
/// fait échouer le test : un vecteur ajouté doit être pris en charge des deux côtés.
struct AttestationDecisionVectorTests {
  private struct UnknownFunction: Error, CustomStringConvertible {
    let name: String
    var description: String { "fonction inconnue : \(name)" }
  }

  private struct Malformed: Error, CustomStringConvertible {
    let field: String
    var description: String { "champ illisible : \(field)" }
  }

  @Test func everyFunctionOfTheContractHasItsVectors() throws {
    let functions = try AttestationVectorFile.all.map { file in
      let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
      #expect(object["format_version"] as? Int == 1, "\(file.name)")
      return try #require(object["function"] as? String)
    }
    #expect(Set(functions) == ["shouldAttempt", "nextState", "responseOutcome"])
  }

  @Test(arguments: AttestationVectorFile.all)
  func vectorFileMatches(_ file: AttestationVectorFile) throws {
    let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    let function = try #require(object["function"] as? String)
    let cases = try #require(object["cases"] as? [[String: Any]])
    #expect(!cases.isEmpty)
    for testCase in cases {
      let name = testCase["name"] as? String ?? "?"
      let input = try #require(testCase["input"] as? [String: Any], "\(file.name) · \(name)")
      let expected = try #require(testCase["expected"], "\(file.name) · \(name)")
      let actual = try Self.evaluate(function, input: input)
      #expect((actual as AnyObject).isEqual(expected), "\(file.name) · \(name) : \(actual) ≠ \(expected)")
    }
  }

  /// Sortie au format des vecteurs : noms des cas d'enum, dates ISO 8601 UTC, `NSNull` pour `null`.
  private static func evaluate(_ function: String, input: [String: Any]) throws -> Any {
    switch function {
    case "shouldAttempt":
      guard let isAnonymous = input["isAnonymous"] as? Bool else { throw Malformed(field: "isAnonymous") }
      let state = try (input["state"] as? [String: Any]).map(Self.state)
      return AttestationDecisions.shouldAttempt(isAnonymous: isAnonymous, state: state, now: try date(input["now"]))
    case "nextState":
      guard let outcome = (input["outcome"] as? String).flatMap(AttestationOutcome.init(rawValue:)) else {
        throw Malformed(field: "outcome")
      }
      let state = AttestationDecisions.nextState(outcome: outcome, now: try date(input["now"]))
      var next: Any = NSNull()
      if let date = state.nextAttemptAt { next = date.formatted(.iso8601) }
      return ["status": state.status.rawValue, "nextAttemptAt": next]
    case "responseOutcome":
      guard let step = (input["step"] as? String).flatMap(AttestationStep.init(rawValue:)) else {
        throw Malformed(field: "step")
      }
      guard let httpStatus = input["httpStatus"] as? Int else { throw Malformed(field: "httpStatus") }
      let response = AttestationDecisions.responseOutcome(
        step: step, httpStatus: httpStatus, status: input["status"] as? String, error: input["error"] as? String)
      return switch response {
      case .proceed: "proceed"
      case .outcome(let outcome): outcome.rawValue
      }
    default:
      throw UnknownFunction(name: function)
    }
  }

  private static func state(_ object: [String: Any]) throws -> AttestationState {
    guard let status = (object["status"] as? String).flatMap(AttestationStatus.init(rawValue:)) else {
      throw Malformed(field: "state.status")
    }
    let next = try (object["nextAttemptAt"] as? String).map { try Date($0, strategy: .iso8601) }
    return AttestationState(status: status, nextAttemptAt: next)
  }

  private static func date(_ value: Any?) throws -> Date {
    guard let text = value as? String else { throw Malformed(field: "now") }
    return try Date(text, strategy: .iso8601)
  }
}

// MARK: - Service

private nonisolated enum AttestationFixtures {
  static let challenge = "Q2hhbGxlbmdlLWRlLXRlc3QtcG91ci1sZS1zZXJ2aWNlLW"
}

/// Passerelle de l'attestation : compte de la session et réponses scénarisées de `attest-device`.
private actor AttestationTestGateway: AttestationGateway {
  /// `nil` : pas de session.
  var account: AttestationAccount?
  /// Compte rendu à partir du deuxième appel de `attestationAccount` (connexion pendant la tentative).
  var accountAfterAttempt: AttestationAccount??
  var challengeReply: Result<AttestationReply, RemoteError>
  var verifyReply: Result<AttestationReply, RemoteError>
  private(set) var challengeCount = 0
  private(set) var verifications: [(challenge: String, keyId: String, attestation: String)] = []
  private var accountReads = 0

  init(
    account: AttestationAccount?,
    challengeReply: Result<AttestationReply, RemoteError> = .success(
      AttestationReply(httpStatus: 200, status: "challenge", challenge: AttestationFixtures.challenge)),
    verifyReply: Result<AttestationReply, RemoteError> = .success(AttestationReply(httpStatus: 200, status: "attested"))
  ) {
    self.account = account
    self.challengeReply = challengeReply
    self.verifyReply = verifyReply
  }

  func setAccountAfterAttempt(_ account: AttestationAccount?) { accountAfterAttempt = .some(account) }
  func setChallengeReply(_ reply: Result<AttestationReply, RemoteError>) { challengeReply = reply }

  func attestationAccount() async throws -> AttestationAccount {
    accountReads += 1
    let current = accountReads > 1 ? (accountAfterAttempt ?? account) : account
    guard let current else { throw RemoteError.unauthorized }
    return current
  }

  func attestationChallenge() async throws -> AttestationReply {
    challengeCount += 1
    return try challengeReply.get()
  }

  func verifyAttestation(challenge: String, keyId: String, attestation: String) async throws -> AttestationReply {
    verifications.append((challenge, keyId, attestation))
    return try verifyReply.get()
  }
}

/// App Attest simulé : clés numérotées, objet d'attestation fixe, erreur au choix.
private actor FakeAttester: DeviceAttester {
  nonisolated let isSupported: Bool
  private let failure: (any Error)?
  private(set) var generatedKeys = 0
  private(set) var hashes: [Data] = []

  init(isSupported: Bool = true, failure: (any Error)? = nil) {
    self.isSupported = isSupported
    self.failure = failure
  }

  func generateKey() async throws -> String {
    generatedKeys += 1
    return "key-\(generatedKeys)"
  }

  func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
    hashes.append(clientDataHash)
    if let failure { throw failure }
    return Data([0xA1, 0x63, 0x66, 0x6D, 0x74])
  }
}

private nonisolated final class FixedClock: AttestationClock, @unchecked Sendable {
  var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite(.serialized)
struct AttestationServiceTests {
  private static let challenge = AttestationFixtures.challenge
  private let anonymous = AttestationAccount(id: UUID(), isAnonymous: true)
  private let clock = FixedClock()
  private let defaults: UserDefaults
  private var store: UserDefaultsAttestationStateStore { UserDefaultsAttestationStateStore(defaults: defaults) }

  init() throws {
    defaults = try #require(UserDefaults(suiteName: "tests.attestation.\(UUID().uuidString)"))
  }

  private func service(_ gateway: AttestationTestGateway, _ attester: FakeAttester = FakeAttester())
    -> DeviceAttestation
  {
    DeviceAttestation(gateway: gateway, attester: attester, store: store, clock: clock)
  }

  @Test func aGenuineDeviceIsAttestedOnceWithAFreshKeyBoundToTheChallenge() async throws {
    let gateway = AttestationTestGateway(account: anonymous)
    let attester = FakeAttester()
    let attestation = service(gateway, attester)

    #expect(await attestation.runOnce() == .attested)

    // SHA-256 de l'UTF-8 du défi, calculé à part.
    let hash = try #require(await attester.hashes.first)
    #expect(hash == DeviceAttestation.clientDataHash(challenge: Self.challenge))
    #expect(
      DeviceAttestation.clientDataHash(challenge: "abc").map { String(format: "%02x", $0) }.joined()
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let sent = try #require(await gateway.verifications.first)
    #expect(sent.challenge == Self.challenge)
    #expect(sent.keyId == "key-1")
    #expect(sent.attestation == Data([0xA1, 0x63, 0x66, 0x6D, 0x74]).base64EncodedString())
    #expect(store.state(for: anonymous.id) == AttestationState(status: .attested, nextAttemptAt: nil))

    // Définitif : plus rien au lancement suivant, même bien plus tard.
    clock.now.addTimeInterval(30 * 86_400)
    #expect(await attestation.runOnce() == nil)
    #expect(await gateway.challengeCount == 1)
    #expect(await attester.generatedKeys == 1)
  }

  @Test func anAccountAlreadyAttestedOnTheServerIsMarkedWithoutAKey() async throws {
    let gateway = AttestationTestGateway(
      account: anonymous, challengeReply: .success(AttestationReply(httpStatus: 200, status: "attested")))
    let attester = FakeAttester()

    #expect(await service(gateway, attester).runOnce() == .attested)
    #expect(await attester.generatedKeys == 0)
    #expect(store.state(for: anonymous.id)?.status == .attested)
  }

  @Test func anUnconfiguredServerIsAskedAgainADayLater() async throws {
    let gateway = AttestationTestGateway(
      account: anonymous, challengeReply: .success(AttestationReply(httpStatus: 200, status: "not_configured")))
    let attester = FakeAttester()
    let attestation = service(gateway, attester)
    let start = clock.now

    #expect(await attestation.runOnce() == .notConfigured)
    #expect(await attester.generatedKeys == 0)
    #expect(
      store.state(for: anonymous.id)
        == AttestationState(status: .pending, nextAttemptAt: start.addingTimeInterval(86_400)))

    clock.now = start.addingTimeInterval(86_399)
    #expect(await attestation.runOnce() == nil)
    clock.now = start.addingTimeInterval(86_400)
    await gateway.setChallengeReply(
      .success(AttestationReply(httpStatus: 200, status: "challenge", challenge: Self.challenge)))
    #expect(await attestation.runOnce() == .attested)
    #expect(await gateway.challengeCount == 2)
  }

  @Test(arguments: ["rejected", "invalid_challenge"])
  func aRefusedProofWaitsAWeek(error: String) async throws {
    let gateway = AttestationTestGateway(
      account: anonymous, verifyReply: .success(AttestationReply(httpStatus: 400, error: error)))
    let start = clock.now

    #expect(await service(gateway).runOnce() == .rejected)
    #expect(
      store.state(for: anonymous.id)
        == AttestationState(status: .pending, nextAttemptAt: start.addingTimeInterval(7 * 86_400)))
  }

  @Test func aNetworkFailureIsRetriedAnHourLaterWithANewKey() async throws {
    let gateway = AttestationTestGateway(account: anonymous, verifyReply: .failure(.network))
    let attester = FakeAttester()
    let attestation = service(gateway, attester)
    let start = clock.now

    #expect(await attestation.runOnce() == .transient)
    #expect(
      store.state(for: anonymous.id)
        == AttestationState(status: .pending, nextAttemptAt: start.addingTimeInterval(3600)))

    // Lancement suivant dans l'heure : rien.
    clock.now = start.addingTimeInterval(1800)
    #expect(await attestation.runOnce() == nil)
    #expect(await gateway.challengeCount == 1)

    // Une heure après : nouvel essai, avec une clé neuve (pas d'assertion).
    clock.now = start.addingTimeInterval(3600)
    #expect(await attestation.runOnce() == .transient)
    #expect(await attester.generatedKeys == 2)
    #expect(await gateway.verifications.map(\.keyId) == ["key-1", "key-2"])
  }

  @Test func noResponseToTheChallengeIsTransient() async throws {
    let gateway = AttestationTestGateway(account: anonymous, challengeReply: .failure(.network))
    let attester = FakeAttester()

    #expect(await service(gateway, attester).runOnce() == .transient)
    #expect(await attester.generatedKeys == 0)
  }

  @Test func anEmailAccountSendsNothing() async throws {
    let account = AttestationAccount(id: UUID(), isAnonymous: false)
    let gateway = AttestationTestGateway(account: account)
    let attester = FakeAttester()

    #expect(await service(gateway, attester).runOnce() == nil)
    #expect(await gateway.challengeCount == 0)
    #expect(await attester.generatedKeys == 0)
    #expect(store.state(for: account.id) == nil)
  }

  @Test func withoutASessionNothingIsTriedNorWritten() async throws {
    let gateway = AttestationTestGateway(account: nil)

    #expect(await service(gateway).runOnce() == nil)
    #expect(await gateway.challengeCount == 0)
    #expect(defaults.object(forKey: UserDefaultsAttestationStateStore.key) == nil)
  }

  @Test func theSimulatorIsUnsupportedForGoodWithoutCallingTheServer() async throws {
    let gateway = AttestationTestGateway(account: anonymous)
    let attester = FakeAttester(isSupported: false)
    let attestation = service(gateway, attester)

    #expect(await attestation.runOnce() == .unsupported)
    #expect(await gateway.challengeCount == 0)
    #expect(store.state(for: anonymous.id) == AttestationState(status: .unsupported, nextAttemptAt: nil))

    clock.now.addTimeInterval(365 * 86_400)
    #expect(await attestation.runOnce() == nil)
  }

  @Test(arguments: [
    (DCError.Code.featureUnsupported, AttestationOutcome.unsupported),
    (.serverUnavailable, .transient), (.invalidKey, .transient), (.invalidInput, .transient),
    (.unknownSystemFailure, .transient),
  ])
  func appAttestErrors(code: DCError.Code, expected: AttestationOutcome) async throws {
    let gateway = AttestationTestGateway(account: anonymous)
    let attester = FakeAttester(failure: DCError(code))

    #expect(await service(gateway, attester).runOnce() == expected)
    // La preuve n'est jamais envoyée : le défi consommé ne sert plus.
    #expect(await gateway.verifications.isEmpty)
    #expect(store.state(for: anonymous.id)?.status == (expected == .unsupported ? .unsupported : .pending))
  }

  @Test func anAccountChangedDuringTheAttemptGetsNothingWritten() async throws {
    let gateway = AttestationTestGateway(account: anonymous)
    let other = AttestationAccount(id: UUID(), isAnonymous: true)
    await gateway.setAccountAfterAttempt(other)

    #expect(await service(gateway).runOnce() == .attested)
    #expect(store.state(for: anonymous.id) == nil)
    #expect(store.state(for: other.id) == nil)
  }

  @Test func theStateOfOneAccountNeverLeaksToAnother() async throws {
    let gateway = AttestationTestGateway(account: anonymous)
    #expect(await service(gateway).runOnce() == .attested)

    // Nouveau compte anonyme (après « Supprimer mes données » ou une déconnexion) : première tentative.
    let next = AttestationAccount(id: UUID(), isAnonymous: true)
    let nextGateway = AttestationTestGateway(account: next)
    #expect(store.state(for: next.id) == nil)
    #expect(await service(nextGateway).runOnce() == .attested)
    #expect(await nextGateway.challengeCount == 1)
    #expect(store.state(for: anonymous.id) == nil)

    store.clear()
    #expect(defaults.object(forKey: UserDefaultsAttestationStateStore.key) == nil)
  }
}
