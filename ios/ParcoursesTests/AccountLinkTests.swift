import Foundation
import SwiftData
import Testing

@testable import Parcourses

/// Doublure des comptes e-mail : réponses de GoTrue programmées, journal des appels.
actor AccountGateway: RemoteGateway {
  var calls: [String] = []
  var linkFailure: (any Error)?
  var signInFailure: (any Error)?
  var verifyFailures: [any Error] = []
  var verified = VerifiedCode(accountId: UUID(), previousAnonymousToken: nil)
  var serverName: String?
  var writtenNames: [String] = []
  var deletedTokens: [String] = []
  var deleteFailure: (any Error)?
  var email: String?
  var localSession: UUID? = UUID()
  var signOutFailure: (any Error)?

  func setLinkFailure(_ error: (any Error)?) { linkFailure = error }
  func setSignInFailure(_ error: (any Error)?) { signInFailure = error }
  func setVerifyFailures(_ errors: [any Error]) { verifyFailures = errors }
  func setVerified(_ value: VerifiedCode) { verified = value }
  func setServerName(_ name: String?) { serverName = name }
  func setDeleteFailure(_ error: (any Error)?) { deleteFailure = error }
  func setEmail(_ value: String?) { email = value }
  func setLocalSession(_ value: UUID?) { localSession = value }

  func linkEmail(_ email: String) async throws {
    calls.append("linkEmail:\(email)")
    if let linkFailure { throw linkFailure }
  }
  func signInWithEmail(_ email: String) async throws {
    calls.append("signInWithEmail:\(email)")
    if let signInFailure { throw signInFailure }
  }
  func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode {
    calls.append("verifyCode:\(purpose.rawValue):\(code)")
    if !verifyFailures.isEmpty { throw verifyFailures.removeFirst() }
    return verified
  }
  func displayName() async throws -> String? {
    calls.append("displayName")
    return serverName
  }
  func setDisplayName(_ name: String) async throws {
    calls.append("setDisplayName")
    writtenNames.append(name)
    serverName = name
  }
  func deleteAccount(accessToken: String) async throws {
    calls.append("deleteAccount(accessToken:)")
    if let deleteFailure { throw deleteFailure }
    deletedTokens.append(accessToken)
  }
  func accountEmail() async throws -> String? { email }
  func signOut() async throws {
    calls.append("signOut")
    if let signOutFailure { throw signOutFailure }
    localSession = nil
  }

  func ensureSession(captchaToken: String?) async throws -> UUID {
    calls.append("ensureSession")
    let id = UUID()
    localSession = id
    return id
  }
  func currentAccountId() async throws -> UUID {
    guard let localSession else { throw RemoteError.unauthorized }
    return localSession
  }
  func verifySession() async throws {}
  func sessionAccountId() async throws -> UUID { try await currentAccountId() }
  func acknowledgeAccount(_ id: UUID) async throws {}
  func serverDate() async throws -> Date? { nil }
  func deleteAccount() async throws { throw RemoteError.unauthorized }
  func signOutLocally() async throws { localSession = nil }
  func localSessionAccountId() async throws -> UUID? { localSession }
  func confirmAccountDeleted() async throws -> Bool { false }
  func saveList(_ list: ListUpsert) async throws { throw RemoteError.unauthorized }
  func deleteList(id: UUID) async throws { throw RemoteError.unauthorized }
  func createVisit(_ visit: VisitInsert) async throws { throw RemoteError.unauthorized }
  func insertChecks(_ checks: [CheckUpload]) async throws { throw RemoteError.unauthorized }
  func closeVisit(id: UUID, endedAt: Date) async throws { throw RemoteError.unauthorized }
  func visitAccess(id: UUID) async throws -> VisitAccess { .notVisible }
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] { [] }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] { [] }
  func fetchCategories() async throws -> [CategoryRow] { [] }
  func fetchProducts() async throws -> [RemoteProduct] { [] }
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow] { [] }
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] { [] }
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] { [] }
  func storeOrganicAisle(id: UUID) async throws -> Bool? { nil }
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse { .none }
}

/// Drapeau `account.kind` en mémoire.
nonisolated final class MemoryAccountKindStore: AccountKindStore, @unchecked Sendable {
  private let lock = NSLock()
  private var value: AccountKind
  init(_ kind: AccountKind = .anonymous) { value = kind }
  var kind: AccountKind { lock.withLock { value } }
  func save(_ kind: AccountKind) { lock.withLock { value = kind } }
}

/// Ce que la liaison a demandé au reste de l'app.
@MainActor
final class LinkProbe {
  var synchronizations = 0
  var sessionChanges = 0
  var online = true
  var now = Date(timeIntervalSince1970: 1_800_000_000)
  var resendable = 0
  /// Appels de la passerelle vus au moment de la synchronisation : l'ordre compte.
  var callsAtSynchronization: [String] = []

  func dependencies(_ gateway: AccountGateway) -> AccountLink.Dependencies {
    AccountLink.Dependencies(
      isOnline: { self.online }, now: { self.now }, resendableLists: { _ in self.resendable },
      synchronize: {
        self.synchronizations += 1
        self.callsAtSynchronization = await gateway.calls
      },
      sessionDidChange: { self.sessionChanges += 1 })
  }
}

@MainActor
@Suite struct AccountLinkTests {
  private func makeLink(kind: AccountKind = .anonymous) -> (
    AccountLink, AccountGateway, MemoryAccountKindStore, LinkProbe
  ) {
    let gateway = AccountGateway()
    let kinds = MemoryAccountKindStore(kind)
    let probe = LinkProbe()
    let link = AccountLink(gateway: gateway, kinds: kinds, dependencies: probe.dependencies(gateway))
    return (link, gateway, kinds, probe)
  }

  @Test func aNewAddressIsLinkedToTheSameAccount() async {
    let (link, gateway, kinds, probe) = makeLink()
    #expect(link.canLink)
    link.email = "  Lea@Exemple.FR "
    link.displayName = " Léa "
    await link.requestCode()
    #expect(link.phase == .enterCode)
    #expect(link.purpose == .link)
    #expect(link.sentTo == "lea@exemple.fr")
    await link.verify(code: "123456")
    #expect(link.phase == .done)
    #expect(link.outcome == .linked)
    #expect(kinds.kind == .email)
    #expect(probe.sessionChanges == 1)
    #expect(probe.synchronizations == 0)
    #expect(await gateway.writtenNames == ["Léa"])
    #expect(
      await gateway.calls == ["linkEmail:lea@exemple.fr", "verifyCode:link:123456", "setDisplayName"])
  }

  /// Vecteur `010` : adresse déjà prise, connexion au compte existant, reprise, puis l'ancien anonyme supprimé.
  @Test func aTakenAddressSignsInMergesThenDeletesTheOldAnonymousAccount() async {
    let (link, gateway, kinds, probe) = makeLink()
    await gateway.setLinkFailure(AuthRequestError(status: 422, code: "email_exists"))
    await gateway.setVerified(VerifiedCode(accountId: UUID(), previousAnonymousToken: "ancien-jeton"))
    await gateway.setServerName("Léa")
    probe.resendable = 2
    link.email = "lea@exemple.fr"
    await link.requestCode()
    #expect(link.purpose == .signIn)
    #expect(await gateway.calls == ["linkEmail:lea@exemple.fr", "signInWithEmail:lea@exemple.fr"])
    await link.verify(code: "654321")
    #expect(link.phase == .done)
    #expect(link.outcome == .signedIn(displayName: "Léa", addedLists: 2))
    #expect(kinds.kind == .email)
    #expect(probe.synchronizations == 1)
    // La reprise d'abord, la suppression de l'ancien compte ensuite.
    #expect(!probe.callsAtSynchronization.contains("deleteAccount(accessToken:)"))
    #expect(await gateway.deletedTokens == ["ancien-jeton"])
    #expect(await gateway.writtenNames.isEmpty)
  }

  @Test func aFailedDeletionOfTheOldAccountChangesNothing() async {
    let (link, gateway, _, _) = makeLink()
    await gateway.setLinkFailure(AuthRequestError(status: 422, code: "email_exists"))
    await gateway.setVerified(VerifiedCode(accountId: UUID(), previousAnonymousToken: "jeton"))
    await gateway.setDeleteFailure(RemoteError.network)
    link.email = "lea@exemple.fr"
    link.displayName = "Léa"
    await link.requestCode()
    await link.verify(code: "111111")
    // Pas de prénom sur le serveur : celui saisi est écrit.
    #expect(link.outcome == .signedIn(displayName: "Léa", addedLists: 0))
    #expect(await gateway.writtenNames == ["Léa"])
  }

  /// Vecteur `009` : compte e-mail sans session, on se reconnecte sans jamais lier.
  @Test func anEmailAccountWithoutSessionOnlySignsIn() async {
    let (link, gateway, _, probe) = makeLink(kind: .email)
    #expect(!link.canLink)
    link.email = "lea@exemple.fr"
    await link.requestCode()
    #expect(link.purpose == .signIn)
    #expect(await gateway.calls == ["signInWithEmail:lea@exemple.fr"])
    await link.verify(code: "222222")
    #expect(link.outcome == .signedIn(displayName: nil, addedLists: 0))
    #expect(probe.synchronizations == 1)
    #expect(await gateway.deletedTokens.isEmpty)
  }

  @Test func errorsAreClassified() async {
    var (link, gateway, _, probe) = makeLink()
    link.email = "pas une adresse"
    await link.requestCode()
    #expect(link.error == .invalidEmail)
    #expect(await gateway.calls.isEmpty)

    link.email = "lea@exemple.fr"
    probe.online = false
    await link.requestCode()
    #expect(link.error == .offline)
    probe.online = true

    await gateway.setLinkFailure(AuthRequestError(status: 429, code: "over_email_send_rate_limit"))
    await link.requestCode()
    #expect(link.error == .rateLimited)
    await gateway.setLinkFailure(RemoteError.network)
    await link.requestCode()
    #expect(link.error == .offline)
    await gateway.setLinkFailure(AuthRequestError(status: 500, code: "unexpected_failure"))
    await link.requestCode()
    #expect(link.error == .unknown)
    await gateway.setLinkFailure(AuthRequestError(status: 400, code: "email_address_invalid"))
    await link.requestCode()
    #expect(link.error == .invalidEmail)
    #expect(link.phase == .enterEmail)

    // Sans compte pour cette adresse, quand on ne peut que se connecter.
    (link, gateway, _, probe) = makeLink(kind: .email)
    link.email = "inconnue@exemple.fr"
    await gateway.setSignInFailure(AuthRequestError(status: 422, code: "otp_disabled"))
    await link.requestCode()
    #expect(link.error == .invalidEmail)
  }

  /// GoTrue répond `otp_expired` à un code faux comme à un code périmé : l'âge du code tranche.
  @Test func aWrongCodeAndAnExpiredCodeAreTold() async {
    let (link, gateway, kinds, probe) = makeLink()
    link.email = "lea@exemple.fr"
    await link.requestCode()
    let wrong = AuthRequestError(status: 403, code: "otp_expired")
    await gateway.setVerifyFailures([wrong, AuthRequestError(status: 429, code: "over_request_rate_limit"), wrong])
    let revision = link.errorRevision
    await link.verify(code: "000000")
    #expect(link.error == .invalidCode)
    #expect(link.errorRevision == revision + 1)
    await link.verify(code: "000000")
    #expect(link.error == .rateLimited)
    probe.now = probe.now.addingTimeInterval(AccountLink.codeLifetime)
    await link.verify(code: "000000")
    #expect(link.error == .expiredCode)
    #expect(link.phase == .enterCode)
    #expect(kinds.kind == .anonymous)
    // Moins de 6 chiffres : rien ne part.
    await link.verify(code: "12a45")
    #expect(await gateway.calls.filter { $0.hasPrefix("verifyCode") }.count == 3)
  }

  @Test func theCodeCanBeSentAgainAfterSixtySecondsOnly() async {
    let (link, gateway, _, probe) = makeLink()
    link.email = "lea@exemple.fr"
    await link.requestCode()
    #expect(link.secondsUntilResend(now: probe.now) == 60)
    await link.resendCode()
    #expect(await gateway.calls.count == 1)
    probe.now = probe.now.addingTimeInterval(59.5)
    #expect(link.secondsUntilResend(now: probe.now) == 1)
    probe.now = probe.now.addingTimeInterval(0.5)
    await link.resendCode()
    #expect(await gateway.calls == ["linkEmail:lea@exemple.fr", "linkEmail:lea@exemple.fr"])

    // Code de connexion : renvoyé par une nouvelle demande de connexion, sans repasser par la liaison.
    await gateway.setLinkFailure(AuthRequestError(status: 422, code: "email_exists"))
    link.changeEmail()
    #expect(link.phase == .enterEmail && link.purpose == nil)
    await link.requestCode()
    probe.now = probe.now.addingTimeInterval(61)
    await link.resendCode()
    #expect(
      await gateway.calls.suffix(3) == [
        "linkEmail:lea@exemple.fr", "signInWithEmail:lea@exemple.fr", "signInWithEmail:lea@exemple.fr",
      ])
  }

  @Test(
    arguments: [
      ("Léa", "Léa"), ("  Jean-Pierre ", "Jean-Pierre"), ("", nil), ("   ", nil),
      (String(repeating: "a", count: 41), nil), (String(repeating: "é", count: 40), String(repeating: "é", count: 40)),
      ("Lé\u{200B}a", nil), ("Léa\u{202E}", nil), ("L\u{0007}a", nil),
    ] as [(String, String?)])
  func displayNamesFollowTheServerRules(raw: String, expected: String?) {
    #expect(AccountLink.validDisplayName(raw) == expected)
  }

  @Test(arguments: [
    ("lea@exemple.fr", true), ("lea.martin+courses@exemple.co.uk", true), ("lea@exemple", false),
    ("léa@exemple.fr", false), ("lea exemple.fr", false), ("@exemple.fr", false),
  ])
  func addressesFollowTheServerForm(email: String, valid: Bool) {
    #expect(AccountLink.isValid(email: AccountLink.normalize(email: email)) == valid)
  }

  @Test func messagesFollowTheMockups() {
    #expect(
      AccountSignInView.message(for: .rateLimited, phase: .enterEmail, unknownAccount: false)
        == "Trop de codes demandés. Réessayez dans 1 min.")
    #expect(
      AccountSignInView.message(for: .rateLimited, phase: .enterCode, unknownAccount: false)
        == "Trop d'essais. Patientez une minute avant de réessayer.")
    #expect(
      AccountSignInView.message(for: .invalidEmail, phase: .enterEmail, unknownAccount: true)
        == "Aucun compte n'utilise cette adresse.")
    #expect(AccountSignInView.addedListsMessage(0) == nil)
    #expect(AccountSignInView.addedListsMessage(1) == "La liste de ce téléphone a été ajoutée à votre compte.")
    #expect(AccountSignInView.addedListsMessage(2) == "Les 2 listes de ce téléphone ont été ajoutées à votre compte.")
  }
}

/// Hôte minimal : compte ce que la déconnexion demande à l'app.
@MainActor
private final class SignOutHost: AccountDeletionHost {
  var steps: [String] = []
  func suspendSync() async { steps.append("suspendSync") }
  func resumeSync() { steps.append("resumeSync") }
  func stopSync() async { steps.append("stopSync") }
  func endShopping() { steps.append("endShopping") }
  func restart() { steps.append("restart") }
}

@MainActor
@Suite(.serialized) struct AccountSessionTests {
  private struct Setup {
    let session: AccountSession
    let gateway: AccountGateway
    let kinds: UserDefaultsAccountKindStore
    let defaults: UserDefaults
    let container: ModelContainer
    var changes: () -> Int
  }

  private func makeSetup(kind: AccountKind) throws -> Setup {
    let defaults = try #require(UserDefaults(suiteName: "tests.account.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(kind)
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let gateway = AccountGateway()
    let purge = LocalDataPurge(
      container: container, keychain: MemorySecureStore(), defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0))
    let counter = Counter()
    let session = AccountSession(
      gateway: gateway, kinds: kinds, purge: purge,
      dependencies: AccountSession.Dependencies(sessionDidChange: { counter.value += 1 }))
    return Setup(
      session: session, gateway: gateway, kinds: kinds, defaults: defaults, container: container,
      changes: { counter.value })
  }

  private final class Counter {
    var value = 0
  }

  @Test func anEmailAccountWithoutSessionWaitsForSignIn() async throws {
    let setup = try makeSetup(kind: .email)
    await setup.gateway.setLocalSession(nil)
    await setup.session.refresh()
    #expect(setup.session.needsSignIn)
    // « Continuer sans compte » : un compte anonyme pourra naître, le moteur reprend.
    setup.session.continueWithoutAccount()
    #expect(!setup.session.needsSignIn)
    #expect(setup.kinds.kind == .anonymous)
    #expect(setup.changes() == 1)
  }

  @Test func aSessionWithAnAddressMakesAnEmailAccount() async throws {
    let setup = try makeSetup(kind: .anonymous)
    await setup.gateway.setEmail("lea@exemple.fr")
    await setup.gateway.setServerName("Léa")
    await setup.session.refresh()
    #expect(setup.session.kind == .email)
    #expect(setup.kinds.kind == .email)
    #expect(setup.session.email == "lea@exemple.fr")
    #expect(setup.session.displayName == "Léa")
    #expect(!setup.session.needsSignIn)
    #expect(await setup.session.updateDisplayName("  Léa M. "))
    #expect(setup.session.displayName == "Léa M.")
    #expect(await setup.session.updateDisplayName("\u{200B}") == false)
  }

  /// Déconnexion : confirmation faite, la session part, l'appareil est purgé (#68), un compte anonyme vide naît.
  @Test func signingOutPurgesTheDeviceAndStartsAnEmptyAnonymousAccount() async throws {
    let setup = try makeSetup(kind: .email)
    await setup.gateway.setEmail("lea@exemple.fr")
    await setup.session.refresh()
    let lists = SwiftDataListRepository(context: setup.container.mainContext)
    _ = try lists.createList(name: "Courses", at: .now)
    #expect(setup.session.losesPendingChanges == false)
    let host = SignOutHost()
    setup.session.host = host
    await setup.session.signOut()
    withExtendedLifetime(host) {}
    #expect(host.steps == ["endShopping", "stopSync", "restart"])
    // `displayName` : lu par `refresh()` avant la déconnexion.
    #expect(await setup.gateway.calls == ["displayName", "signOut", "ensureSession"])
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(setup.defaults.string(forKey: UserDefaultsAccountKindStore.key) == nil)
    #expect(setup.session.kind == .anonymous)
    #expect(setup.session.email == nil)
  }
}
