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
  /// `localSessionAccountId` lève (Keychain verrouillé).
  var sessionReadFailure: (any Error)?
  /// `accountEmail` lève sans session, comme la passerelle Android : le rejeu ne doit pas en dépendre.
  var emailFailsWithoutSession = false

  func setLinkFailure(_ error: (any Error)?) { linkFailure = error }
  func setSignInFailure(_ error: (any Error)?) { signInFailure = error }
  func setVerifyFailures(_ errors: [any Error]) { verifyFailures = errors }
  func setVerified(_ value: VerifiedCode) { verified = value }
  func setServerName(_ name: String?) { serverName = name }
  func setDeleteFailure(_ error: (any Error)?) { deleteFailure = error }
  func setEmail(_ value: String?) { email = value }
  func setLocalSession(_ value: UUID?) { localSession = value }
  func setSessionReadFailure(_ error: (any Error)?) { sessionReadFailure = error }
  func setSignOutFailure(_ error: (any Error)?) { signOutFailure = error }
  func setEmailFailsWithoutSession(_ value: Bool) { emailFailsWithoutSession = value }
  /// `acknowledgeAccount` lève : le changement de compte échoue à l'étape `session` (#129).
  var acknowledgeFailure: (any Error)?
  func setAcknowledgeFailure(_ error: (any Error)?) { acknowledgeFailure = error }

  func linkEmail(_ email: String) async throws {
    calls.append("linkEmail:\(email)")
    if let linkFailure { throw linkFailure }
  }
  func signInWithEmail(_ email: String) async throws {
    calls.append("signInWithEmail:\(email)")
    if let signInFailure { throw signInFailure }
  }
  var verifyDelay: Duration?
  func setVerifyDelay(_ value: Duration?) { verifyDelay = value }
  func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode {
    calls.append("verifyCode:\(purpose.rawValue):\(code)")
    if let verifyDelay { try await Task.sleep(for: verifyDelay) }
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
  func accountEmail() async throws -> String? {
    if emailFailsWithoutSession, localSession == nil { throw RemoteError.unauthorized }
    return email
  }
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
  func acknowledgeAccount(_ id: UUID) async throws {
    if let acknowledgeFailure { throw acknowledgeFailure }
  }
  func serverDate() async throws -> Date? { nil }
  func deleteAccount() async throws { throw RemoteError.unauthorized }
  func signOutLocally() async throws { localSession = nil }
  func localSessionAccountId() async throws -> UUID? {
    if let sessionReadFailure { throw sessionReadFailure }
    return localSession
  }
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
  var previousAccount: UUID?
  var pending = 0
  /// Ordre des étapes demandées à l'app : arrêt et reprise de la synchro, changement de compte, synchro.
  var steps: [String] = []
  var switchFailure: (any Error)?
  /// Drapeau `account.switch`.
  var switchFlag = false

  func dependencies(_ gateway: AccountGateway) -> AccountLink.Dependencies {
    AccountLink.Dependencies(
      isOnline: { self.online }, now: { self.now }, resendableLists: { _ in self.resendable },
      synchronize: {
        self.synchronizations += 1
        self.steps.append("synchronize")
        self.callsAtSynchronization = await gateway.calls
      },
      sessionDidChange: { self.sessionChanges += 1 },
      previousAccountId: { self.previousAccount }, pendingChanges: { self.pending },
      suspendSync: {
        let calls = await gateway.calls
        self.steps.append("suspend:\(calls.count)")
      },
      resumeSync: { self.steps.append("resume") },
      markSwitch: { self.switchFlag = $0 },
      isSwitchPending: { self.switchFlag },
      switchAccount: { id in
        self.steps.append("switch")
        if let failure = self.switchFailure { throw failure }
        _ = id
      })
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

  /// Synchro arrêtée avant la vérification, reprise après, succès comme échec.
  @Test func syncIsSuspendedAroundTheVerification() async {
    let (link, gateway, _, probe) = makeLink()
    link.email = "lea@exemple.fr"
    await link.requestCode()
    await gateway.setVerifyFailures([AuthRequestError(status: 403, code: "otp_expired")])
    await link.verify(code: "000000")
    // Arrêt avant l'appel (1 appel : la liaison), reprise après l'échec.
    #expect(probe.steps == ["suspend:1", "resume"])
    await link.verify(code: "123456")
    #expect(probe.steps == ["suspend:1", "resume", "suspend:2", "resume"])
  }

  /// L'annulation de l'appelant (écran fermé) n'interrompt ni la vérification ni la reprise de la synchro.
  @Test func cancellingTheCallerDoesNotInterruptTheVerification() async {
    let (link, gateway, kinds, probe) = makeLink()
    link.email = "lea@exemple.fr"
    await link.requestCode()
    await gateway.setVerifyDelay(.milliseconds(100))
    let caller = Task { await link.verify(code: "123456") }
    caller.cancel()
    await caller.value
    #expect(link.outcome == .linked)
    #expect(kinds.kind == .email)
    #expect(probe.steps == ["suspend:1", "resume"])
  }

  /// D'un compte e-mail à un autre : l'appareil est purgé avant la reprise de la synchro, rien n'est renvoyé.
  @Test func anotherEmailAccountReplacesTheDeviceData() async {
    let (link, gateway, _, probe) = makeLink(kind: .email)
    probe.previousAccount = UUID()
    probe.resendable = 3
    probe.pending = 2
    #expect(link.losesPendingChangesOnSwitch)
    await gateway.setVerified(VerifiedCode(accountId: UUID(), previousAnonymousToken: nil))
    link.email = "autre@exemple.fr"
    await link.requestCode()
    await link.verify(code: "333333")
    #expect(probe.steps == ["suspend:1", "switch", "resume", "synchronize"])
    #expect(link.outcome == .signedIn(displayName: nil, addedLists: 0))
  }

  /// Un code refusé n'efface `account.switch` que si cet essai l'a posé : celui d'un essai interrompu protège une purge
  /// encore due.
  @Test(arguments: [false, true]) func aRefusedCodeClearsOnlyTheSwitchFlagItSet(alreadyPending: Bool) async {
    let (link, gateway, _, probe) = makeLink(kind: .email)
    probe.switchFlag = alreadyPending
    link.email = "lea@exemple.fr"
    await link.requestCode()
    await gateway.setVerifyFailures([AuthRequestError(status: 403, code: "otp_expired")])
    await link.verify(code: "000000")
    #expect(link.error == .invalidCode)
    #expect(probe.switchFlag == alreadyPending)
  }

  /// Même compte (reconnexion) : pas de purge.
  @Test func theSameEmailAccountKeepsTheDeviceData() async {
    let (link, gateway, _, probe) = makeLink(kind: .email)
    let account = UUID()
    probe.previousAccount = account
    await gateway.setVerified(VerifiedCode(accountId: account, previousAnonymousToken: nil))
    link.email = "lea@exemple.fr"
    await link.requestCode()
    await link.verify(code: "444444")
    #expect(!probe.steps.contains("switch"))
    #expect(link.phase == .done)
  }

  /// Purge impossible : la session du nouveau compte est oubliée, on attend une nouvelle connexion sans rien renvoyer.
  @Test func aFailedSwitchSignsOutAndWaits() async {
    struct PurgeFailure: Error {}
    let (link, gateway, _, probe) = makeLink(kind: .email)
    probe.previousAccount = UUID()
    probe.switchFailure = PurgeFailure()
    link.email = "autre@exemple.fr"
    await link.requestCode()
    await link.verify(code: "555555")
    #expect(link.error == .unknown)
    #expect(link.phase == .enterEmail)
    #expect(await gateway.calls.last == "signOut")
    #expect(probe.steps == ["suspend:1", "switch", "resume"])
    #expect(probe.synchronizations == 0)
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
    let previous: Previous
  }

  private func makeSetup(kind: AccountKind, signOutPending: Bool = false) throws -> Setup {
    let defaults = try #require(UserDefaults(suiteName: "tests.account.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(kind)
    if signOutPending { UserDefaultsAccountSignOutFlagStore(defaults: defaults).save() }
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let gateway = AccountGateway()
    let purge = LocalDataPurge(
      container: container, keychain: MemorySecureStore(), defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0))
    let counter = Counter()
    let previous = Previous()
    let session = AccountSession(
      gateway: gateway, kinds: kinds, purge: purge,
      signOutFlags: UserDefaultsAccountSignOutFlagStore(defaults: defaults),
      switchFlags: UserDefaultsAccountSwitchFlagStore(defaults: defaults),
      cursors: UserDefaultsSyncCursors(defaults: defaults),
      dependencies: AccountSession.Dependencies(
        // Comme l'app : `pending` et `failed`.
        pendingChanges: { (try? container.mainContext.fetchCount(FetchDescriptor<OutboxEntry>())) ?? 0 },
        sessionDidChange: { counter.value += 1 },
        link: AccountLink.Dependencies(previousAccountId: { previous.value })))
    return Setup(
      session: session, gateway: gateway, kinds: kinds, defaults: defaults, container: container,
      changes: { counter.value }, previous: previous)
  }

  private final class Counter {
    var value = 0
  }

  /// `SyncCursors.accountId` simulé.
  final class Previous {
    var value: UUID?
  }

  /// « Continuer sans compte » : l'appareil est purgé d'abord, puis un compte anonyme vide naît.
  @Test func anEmailAccountWithoutSessionWaitsForSignInOrStartsEmpty() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "Courses", at: .now)
    await setup.gateway.setLocalSession(nil)
    await setup.session.refresh()
    #expect(setup.session.needsSignIn)
    let host = SignOutHost()
    setup.session.host = host
    #expect(await setup.session.prepareToLeave())
    await setup.session.continueWithoutAccount()
    withExtendedLifetime(host) {}
    #expect(host.steps == ["suspendSync", "endShopping", "stopSync", "restart"])
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(setup.kinds.kind == .anonymous)
    #expect(!setup.session.needsSignIn)
    #expect(await setup.gateway.calls == ["ensureSession"])
  }

  /// Déconnexion : la synchro est suspendue avant de compter la file, entrées `failed` comprises.
  @Test func leavingCountsPendingAndFailedEntriesAfterSuspendingSync() async throws {
    let setup = try makeSetup(kind: .email)
    let context = setup.container.mainContext
    context.insert(OutboxEntry(sequence: 1, kind: .upsertList, entityId: UUID(), payload: Data(), syncState: .failed))
    try context.save()
    let host = SignOutHost()
    setup.session.host = host
    #expect(await setup.session.prepareToLeave())
    #expect(host.steps == ["suspendSync"])
    setup.session.cancelLeaving()
    #expect(host.steps == ["suspendSync", "resumeSync"])
    withExtendedLifetime(host) {}
  }

  /// Drapeau `account.switch` et session d'un autre compte au lancement : purge rejouée, aucune reprise.
  @Test func anInterruptedAccountSwitchIsFinishedAtLaunch() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "De A", at: .now)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    setup.previous.value = UUID()
    let accountB = UUID()
    await setup.gateway.setLocalSession(accountB)
    await setup.gateway.setEmail("b@exemple.fr")
    #expect(await setup.session.resumePendingSwitch())
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(!flags.isPending)
    #expect(setup.kinds.kind == .email)
    // B est aussitôt le compte des données : une connexion à C avant la première passe ne reprendrait rien de B.
    let cursors = UserDefaultsSyncCursors(defaults: setup.defaults)
    #expect(cursors.accountId == accountB)
    #expect(cursors.accountKind == .email)
  }

  /// Compte e-mail reconnecté par « Se reconnecter » (jamais de session), app tuée pendant `verifyCode` : sans session,
  /// rien à protéger. Le drapeau est effacé sans lire l'adresse (qui lève sans session sur Android), rien n'est purgé,
  /// et le bandeau « Reconnectez-vous » revient.
  @Test func anInterruptedSwitchWithoutSessionClearsTheFlagAndShowsTheBanner() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "De A", at: .now)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    setup.previous.value = UUID()
    await setup.gateway.setLocalSession(nil)
    await setup.gateway.setEmailFailsWithoutSession(true)
    #expect(await setup.session.resumePendingSwitch())
    #expect(!flags.isPending)
    #expect(!setup.session.switchResumeFailed)
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 1)
    await setup.session.refresh()
    #expect(setup.session.needsSignIn)
  }

  /// Changement achevé par le rejeu (purge en échec, puis retour au premier plan), puis un nouvel essai : les données
  /// sont déjà celles de B, rien n'est purgé une seconde fois.
  @Test func anAlreadyFinishedSwitchIsNotPurgedTwice() async throws {
    let setup = try makeSetup(kind: .email)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    setup.previous.value = UUID()
    let accountB = UUID()
    await setup.gateway.setLocalSession(accountB)
    await setup.gateway.setEmail("b@exemple.fr")
    #expect(await setup.session.resumePendingSwitch())
    #expect(!flags.isPending)
    // Faite depuis sur B, hors ligne : elle doit survivre au nouvel essai.
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "De B", at: .now)
    try await setup.session.adoptAccount(accountB)
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 1)
    #expect(UserDefaultsSyncCursors(defaults: setup.defaults).accountId == accountB)
  }

  /// Session anonyme avec le drapeau : aucun compte e-mail n'a été ouvert, rien n'est purgé ni adopté.
  @Test func anAnonymousSessionClearsTheSwitchFlagWithoutPurging() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "De A", at: .now)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    setup.previous.value = UUID()
    await setup.gateway.setLocalSession(UUID())
    await setup.gateway.setEmail(nil)
    #expect(await setup.session.resumePendingSwitch())
    #expect(!flags.isPending)
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 1)
    #expect(UserDefaultsSyncCursors(defaults: setup.defaults).accountId == nil)
  }

  /// Rejeu en échec (Keychain verrouillé) : la synchro reste arrêtée et l'app réessaie au retour au premier plan.
  @Test func aFailedSwitchReplayIsRetriedLater() async throws {
    let setup = try makeSetup(kind: .email)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    await setup.gateway.setSessionReadFailure(RemoteError.keychainLocked)
    #expect(await setup.session.resumePendingSwitch() == false)
    #expect(setup.session.switchResumeFailed)
    #expect(setup.session.hasPendingSwitch)
    await setup.gateway.setSessionReadFailure(nil)
    setup.previous.value = await setup.gateway.localSession
    #expect(await setup.session.resumePendingSwitch())
    #expect(!setup.session.switchResumeFailed)
    #expect(!flags.isPending)
  }

  /// Le rejeu de lancement attend la fin d'une vérification de code en cours : jamais de purge en plein milieu.
  @Test func aSwitchReplayWaitsForACodeBeingVerified() async throws {
    let setup = try makeSetup(kind: .email)
    let account = UUID()
    setup.previous.value = account
    await setup.gateway.setLocalSession(nil)
    await setup.gateway.setVerified(VerifiedCode(accountId: account, previousAnonymousToken: nil))
    await setup.gateway.setVerifyDelay(.milliseconds(300))
    let link = try #require(setup.session.makeLink())
    link.email = "lea@exemple.fr"
    await link.requestCode()
    #expect(link.purpose == .signIn)
    let verifying = Task { await link.verify(code: "123456") }
    while await !setup.gateway.calls.contains(where: { $0.hasPrefix("verifyCode") }) {
      try await Task.sleep(for: .milliseconds(5))
    }
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    #expect(flags.isPending)
    #expect(await setup.session.resumePendingSwitch())
    // Le rejeu n'a tourné qu'après la vérification et sa reprise.
    #expect(link.phase == .done)
    #expect(!flags.isPending)
    await verifying.value
  }

  /// Même compte : le drapeau est effacé, rien n'est purgé.
  @Test func anAccountSwitchFlagWithTheSameAccountIsCleared() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "À moi", at: .now)
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    flags.save()
    let account = UUID()
    setup.previous.value = account
    await setup.gateway.setLocalSession(account)
    #expect(await setup.session.resumePendingSwitch())
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 1)
    #expect(!flags.isPending)
  }

  /// `account.kind` absent, session non anonyme : compte e-mail.
  @Test func aMissingKindWithANonAnonymousSessionIsEmail() async throws {
    let setup = try makeSetup(kind: .anonymous)
    setup.defaults.removeObject(forKey: UserDefaultsAccountKindStore.key)
    await setup.gateway.setEmail("lea@exemple.fr")
    UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults).save()
    setup.previous.value = await setup.gateway.localSession
    #expect(await setup.session.resumePendingSwitch())
    #expect(setup.kinds.kind == .email)
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
    // La liste n'est pas encore partie : la confirmation le dit.
    #expect(setup.session.losesPendingChanges)
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
    #expect(!UserDefaultsAccountSignOutFlagStore(defaults: setup.defaults).isPending)
  }

  /// La purge de la déconnexion efface aussi `account.switch` : plus rien à purger pour un changement de compte.
  @Test func theSignOutPurgeClearsTheSwitchFlag() async throws {
    let setup = try makeSetup(kind: .email, signOutPending: true)
    let switchFlags = UserDefaultsAccountSwitchFlagStore(defaults: setup.defaults)
    switchFlags.save()
    #expect(setup.session.isSignOutPending)
    #expect(setup.session.makeLink() == nil)
    #expect(setup.session.resumePendingSignOut())
    #expect(!switchFlags.isPending)
    #expect(!setup.session.isSignOutPending)
    #expect(setup.session.makeLink() != nil)
  }

  /// Connexion de A vers B : la purge échoue, puis la déconnexion de secours aussi. Le drapeau reste posé sans que le
  /// rejeu de lancement ait échoué : le retour au premier plan rejoue quand même le changement, et la synchro repart.
  @Test func aSwitchHeldForPurgeAfterAVerifiedCodeIsReplayedInTheForeground() async throws {
    struct SeedFailure: Error {}
    let defaults = try #require(UserDefaults(suiteName: "tests.account.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(.email)
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    _ = try SwiftDataListRepository(context: container.mainContext).createList(name: "De A", at: .now)
    let gateway = AccountGateway()
    let accountB = UUID()
    await gateway.setLocalSession(accountB)
    await gateway.setEmail("b@exemple.fr")
    await gateway.setVerified(VerifiedCode(accountId: accountB, previousAnonymousToken: nil))
    await gateway.setSignOutFailure(RemoteError.keychainLocked)
    let fails = Counter()
    fails.value = 1
    let purge = LocalDataPurge(
      container: container, keychain: MemorySecureStore(), defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0),
      seedSource: {
        if fails.value > 0 {
          fails.value -= 1
          throw SeedFailure()
        }
        return try CategorySeed.bundled()
      })
    let cursors = UserDefaultsSyncCursors(defaults: defaults)
    cursors.accountId = UUID()
    cursors.accountKind = .email
    let flags = UserDefaultsAccountSwitchFlagStore(defaults: defaults)
    let session = AccountSession(
      gateway: gateway, kinds: kinds, purge: purge,
      signOutFlags: UserDefaultsAccountSignOutFlagStore(defaults: defaults), switchFlags: flags, cursors: cursors,
      dependencies: AccountSession.Dependencies(
        link: AccountLink.Dependencies(previousAccountId: { cursors.accountId })))
    let link = try #require(session.makeLink())
    link.email = "b@exemple.fr"
    await link.requestCode()
    await link.verify(code: "123456")
    #expect(link.error == .unknown)
    #expect(flags.isPending)
    #expect(!session.switchResumeFailed)
    #expect(session.hasPendingSwitch)
    #expect(await session.replayPendingSwitch())
    #expect(!flags.isPending)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(cursors.accountId == accountB)
    // Plus rien de dû : le retour suivant ne rejoue rien.
    #expect(await session.replayPendingSwitch() == false)
  }

  /// Arrêt de l'app après la pose du drapeau : la purge est faite au lancement suivant.
  @Test func anInterruptedSignOutIsFinishedAtLaunch() async throws {
    let setup = try makeSetup(kind: .email)
    _ = try SwiftDataListRepository(context: setup.container.mainContext).createList(name: "Courses", at: .now)
    let flags = UserDefaultsAccountSignOutFlagStore(defaults: setup.defaults)
    flags.save()
    #expect(setup.session.resumePendingSignOut())
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(!flags.isPending)
    #expect(setup.session.kind == .anonymous)
  }

  /// Purge en échec : ni reconstruction ni compte anonyme, « Réessayer » ; le drapeau reste jusqu'au succès.
  @Test func aFailedPurgeOffersARetry() async throws {
    struct SeedFailure: Error {}
    let defaults = try #require(UserDefaults(suiteName: "tests.account.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(.email)
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let gateway = AccountGateway()
    await gateway.setEmail("lea@exemple.fr")
    let fails = Counter()
    fails.value = 1
    let purge = LocalDataPurge(
      container: container, keychain: MemorySecureStore(), defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0),
      seedSource: {
        if fails.value > 0 {
          fails.value -= 1
          throw SeedFailure()
        }
        return try CategorySeed.bundled()
      })
    let flags = UserDefaultsAccountSignOutFlagStore(defaults: defaults)
    let session = AccountSession(
      gateway: gateway, kinds: kinds, purge: purge, signOutFlags: flags,
      switchFlags: UserDefaultsAccountSwitchFlagStore(defaults: defaults))
    await session.refresh()
    let host = SignOutHost()
    session.host = host
    await session.signOut()
    #expect(session.signOutFailed)
    #expect(flags.isPending)
    // Seul « Réessayer » : un compte ouvert maintenant serait effacé par la purge rejouée au lancement.
    #expect(session.isSignOutPending)
    #expect(session.makeLink() == nil)
    #expect(!host.steps.contains("restart"))
    #expect(await !gateway.calls.contains("ensureSession"))
    await session.retrySignOut()
    withExtendedLifetime(host) {}
    #expect(!session.signOutFailed)
    #expect(!flags.isPending)
    #expect(!session.isSignOutPending)
    #expect(host.steps.last == "restart")
    #expect(await gateway.calls.last == "ensureSession")
  }
}

/// Tant qu'un drapeau de purge est posé (déconnexion, changement de compte, suppression), aucune reprise ne relance le
/// moteur : la purge rejouée au lancement suivant effacerait ce qu'il aurait envoyé ou reçu.
@MainActor
@Suite(.serialized) struct SyncRuntimeHoldTests {
  private nonisolated final class MemoryFlag: AccountSignOutFlagStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isPending: Bool { lock.withLock { value } }
    func save() { lock.withLock { value = true } }
    func clear() { lock.withLock { value = false } }
  }

  @Test(arguments: ["signOut", "switch"]) func aPendingPurgeFlagKeepsTheEngineSuspended(flag: String) async throws {
    let defaults = try #require(UserDefaults(suiteName: "tests.runtime.\(UUID().uuidString)"))
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let gateway = ScriptedSyncGateway()
    let signOut = MemoryFlag(flag == "signOut")
    let switching = MemoryFlag(flag == "switch")
    let runtime = try SyncRuntime(
      gateway: gateway, container: container, deletionFlags: UserDefaultsAccountDeletionFlagStore(defaults: defaults),
      signOutFlags: signOut, switchFlags: switching, cursors: MemorySyncCursors())
    #expect(runtime.isHeldForPurge)
    // Point de synchronisation explicite : chaque reprise lancée est attendue jusqu'au bout avant de lire l'état du
    // moteur. Sans la garde de `SyncRuntime`, elles reprennent le moteur et l'assertion échoue à coup sûr.
    await runtime.resume()?.value
    #expect(await runtime.isEngineSuspended, "resume()")
    await runtime.sessionDidChange()?.value
    #expect(await runtime.isEngineSuspended, "sessionDidChange()")
    await runtime.resumeAndWait()
    #expect(await runtime.isEngineSuspended, "resumeAndWait()")
    await runtime.synchronize()
    #expect(await gateway.calls.isEmpty)
    // Drapeau effacé par la purge : la reprise passe.
    signOut.clear()
    switching.clear()
    await runtime.resumeAndWait()
    #expect(await !runtime.isEngineSuspended)
    await runtime.synchronize()
    #expect(await !gateway.calls.isEmpty)
    await runtime.stop()
  }
}
