import Foundation
import SwiftData
import Testing

@testable import Parcourses

/// Code public et `mailto:` de « Nous écrire » (#129) : mêmes valeurs sur Android.
struct PurgeFailureCodeTests {
  nonisolated static let codes: [(PurgeFailure, String)] = [
    (PurgeFailure(operation: .signOut, step: .store), "purge-signout-store"),
    (PurgeFailure(operation: .signOut, step: .categories), "purge-signout-categories"),
    (PurgeFailure(operation: .signOut, step: .session), "purge-signout-session"),
    (PurgeFailure(operation: .signOut, step: .preferences), "purge-signout-preferences"),
    (PurgeFailure(operation: .signOut, step: .unknown), "purge-signout-unknown"),
    (PurgeFailure(operation: .switch, step: .store), "purge-switch-store"),
    (PurgeFailure(operation: .switch, step: .categories), "purge-switch-categories"),
    (PurgeFailure(operation: .switch, step: .session), "purge-switch-session"),
    (PurgeFailure(operation: .switch, step: .preferences), "purge-switch-preferences"),
    (PurgeFailure(operation: .switch, step: .unknown), "purge-switch-unknown"),
  ]

  @Test(arguments: codes)
  func eachStepHasItsPublicCode(failure: PurgeFailure, code: String) {
    #expect(failure.publicCode == code)
  }

  @Test func everyOperationAndStepIsCovered() {
    #expect(Self.codes.count == PurgeOperation.allCases.count * PurgeStep.allCases.count)
    #expect(Set(Self.codes.map(\.1)).count == Self.codes.count)
  }

  @Test func purgeStepsMapToPublicSteps() {
    #expect(PurgeStep(LocalDataPurge.Step.storePurged) == .store)
    #expect(PurgeStep(LocalDataPurge.Step.categoriesSeeded) == .categories)
    #expect(PurgeStep(LocalDataPurge.Step.keychainPurged) == .session)
    #expect(PurgeStep(LocalDataPurge.Step.preferencesPurged) == .preferences)
    struct Other: Error {}
    #expect(PurgeStep(of: LocalDataPurge.Failure(step: .categoriesSeeded, underlying: Other())) == .categories)
    #expect(PurgeStep(of: PurgeSessionFailure(underlying: Other())) == .session)
    #expect(PurgeStep(of: Other()) == .unknown)
  }

  @Test func theSupportMailtoIsExact() {
    let url = PurgeFailure(operation: .signOut, step: .store).supportMailto
    #expect(
      url.absoluteString
        == "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28purge-signout-store%29")
  }

  /// Une adresse, un objet, pas de corps : seuls les caractères non réservés restent en clair.
  @Test(arguments: codes)
  func theSupportMailtoHasOnlyASubject(failure: PurgeFailure, code: String) throws {
    let url = failure.supportMailto
    #expect(
      url.absoluteString
        == "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28\(code)%29")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.scheme == "mailto")
    #expect(components.path == "parcourses@hadrien.eu")
    #expect(components.queryItems?.map(\.name) == ["subject"])
    #expect(components.queryItems?.first?.value == "Parcourses : purge impossible (\(code))")
  }
}

/// Étape en échec d'une vraie purge : la première qui lève donne le code.
@MainActor
@Suite(.serialized) struct LocalDataPurgeFailureTests {
  private struct Injected: Error {}

  private func makePurge(
    keychain: MemorySecureStore = MemorySecureStore(),
    seedSource: @escaping @MainActor () throws -> CategorySeed = CategorySeed.bundled,
    failing failed: LocalDataPurge.Step? = nil
  ) throws -> LocalDataPurge {
    let defaults = try #require(UserDefaults(suiteName: "tests.purge-failure.\(UUID().uuidString)"))
    return LocalDataPurge(
      container: try PersistenceStack.makeContainer(storage: .inMemory), keychain: keychain, defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0), seedSource: seedSource,
      injectedFailure: { step in
        if step == failed { throw Injected() }
      })
  }

  private func failedStep(_ purge: LocalDataPurge) -> PurgeStep? {
    do {
      try purge.run()
      return nil
    } catch {
      return PurgeStep(of: error)
    }
  }

  @Test(arguments: [
    (LocalDataPurge.Step.storePurged, PurgeStep.store), (.categoriesSeeded, .categories), (.keychainPurged, .session),
    (.preferencesPurged, .preferences),
  ])
  func anInjectedFailureNamesItsStep(step: LocalDataPurge.Step, expected: PurgeStep) throws {
    #expect(failedStep(try makePurge(failing: step)) == expected)
  }

  @Test func realFailuresNameTheirStep() throws {
    struct SeedFailure: Error {}
    #expect(failedStep(try makePurge(seedSource: { throw SeedFailure() })) == .categories)
    let keychain = MemorySecureStore()
    keychain.failsRemoveAll = true
    #expect(failedStep(try makePurge(keychain: keychain)) == .session)
    #expect(failedStep(try makePurge()) == nil)
  }

  /// Un arrêt simulé (`checkpoint`) traverse tel quel : la suppression du compte le reconnaît.
  @Test func aCheckpointHaltIsNotWrapped() throws {
    struct Halt: Error {}
    let purge = try makePurge()
    #expect(throws: Halt.self) { try purge.run { _ in throw Halt() } }
  }
}

/// Compteur `purgeFailureCount` (#129) : +1 à chaque purge en échec, 0 sur un succès, seuil au 3ᵉ.
@MainActor
@Suite(.serialized) struct PurgeFailureCountTests {
  private struct Injected: Error {}

  /// Les `remaining` prochaines purges échouent à leur première étape.
  private final class Faults {
    var remaining: Int
    init(_ remaining: Int) { self.remaining = remaining }
  }

  private final class Previous {
    var value: UUID?
  }

  /// Ce que la session demande à l'app.
  private final class Host: AccountDeletionHost {
    var steps: [String] = []
    func suspendSync() async { steps.append("suspendSync") }
    func resumeSync() { steps.append("resumeSync") }
    func stopSync() async { steps.append("stopSync") }
    func endShopping() { steps.append("endShopping") }
    func restart() { steps.append("restart") }
  }

  private struct Setup {
    let session: AccountSession
    let gateway: AccountGateway
    let container: ModelContainer
    let faults: Faults
    let host: Host
    let switchFlags: UserDefaultsAccountSwitchFlagStore
    let previous: Previous
  }

  private func makeSetup(failures: Int, signOutPending: Bool = false, switchPending: Bool = false) async throws
    -> Setup
  {
    let defaults = try #require(UserDefaults(suiteName: "tests.purge-count.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    kinds.save(.email)
    let signOutFlags = UserDefaultsAccountSignOutFlagStore(defaults: defaults)
    if signOutPending { signOutFlags.save() }
    let switchFlags = UserDefaultsAccountSwitchFlagStore(defaults: defaults)
    if switchPending { switchFlags.save() }
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    _ = try SwiftDataListRepository(context: container.mainContext).createList(name: "Courses", at: .now)
    let gateway = AccountGateway()
    await gateway.setEmail("lea@exemple.fr")
    let faults = Faults(failures)
    let purge = LocalDataPurge(
      container: container, keychain: MemorySecureStore(), defaults: defaults,
      urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0),
      injectedFailure: { step in
        guard step == .storePurged, faults.remaining > 0 else { return }
        faults.remaining -= 1
        throw Injected()
      })
    let previous = Previous()
    let session = AccountSession(
      gateway: gateway, kinds: kinds, purge: purge, signOutFlags: signOutFlags, switchFlags: switchFlags,
      cursors: UserDefaultsSyncCursors(defaults: defaults),
      dependencies: AccountSession.Dependencies(
        link: AccountLink.Dependencies(previousAccountId: { previous.value })))
    let host = Host()
    session.host = host
    return Setup(
      session: session, gateway: gateway, container: container, faults: faults, host: host, switchFlags: switchFlags,
      previous: previous)
  }

  /// Changement de compte vers B interrompu : la session est celle de B, les données celles d'un autre compte.
  private func prepareSwitch(_ setup: Setup) async {
    setup.previous.value = UUID()
    await setup.gateway.setLocalSession(UUID())
    await setup.gateway.setEmail("b@exemple.fr")
  }

  @Test func theThresholdIsThree() {
    #expect(AccountSession.purgeFailureThreshold == 3)
  }

  /// Déconnexion : essai puis « Réessayer ». L'aide n'apparaît qu'au 3ᵉ échec, tout revient à 0 au succès.
  @Test func signOutFailuresAreCountedUntilASuccess() async throws {
    let setup = try await makeSetup(failures: 3)
    await setup.session.refresh()
    let accountId = try #require(await setup.gateway.localSession).uuidString
    #expect(setup.session.purgeFailureCount == 0)
    await setup.session.signOut()
    #expect(setup.session.signOutFailed)
    #expect(setup.session.purgeFailureCount == 1)
    #expect(!setup.session.needsPurgeHelp)
    #expect(setup.session.lastPurgeFailure == PurgeFailure(operation: .signOut, step: .store))
    await setup.session.retrySignOut()
    #expect(setup.session.purgeFailureCount == 2)
    #expect(!setup.session.needsPurgeHelp)
    await setup.session.retrySignOut()
    #expect(setup.session.signOutFailed)
    #expect(setup.session.purgeFailureCount == 3)
    #expect(setup.session.needsPurgeHelp)
    // Aucune donnée personnelle dans le mail : ni adresse, ni identifiant de compte, ni texte d'erreur.
    let mailto = try #require(setup.session.lastPurgeFailure?.supportMailto.absoluteString)
    #expect(mailto.hasSuffix("%28purge-signout-store%29"))
    for secret in ["lea", "exemple", "Injected", accountId] {
      #expect(!mailto.contains(secret), "\(secret)")
    }
    await setup.session.retrySignOut()
    #expect(!setup.session.signOutFailed)
    #expect(setup.session.purgeFailureCount == 0)
    #expect(setup.session.lastPurgeFailure == nil)
    #expect(!setup.session.needsPurgeHelp)
    #expect(setup.host.steps.last == "restart")
  }

  /// « Continuer sans compte » passe par la même purge : un échec compte.
  @Test func continuingWithoutAccountCountsAFailedPurge() async throws {
    let setup = try await makeSetup(failures: 1)
    await setup.gateway.setLocalSession(nil)
    await setup.session.refresh()
    #expect(setup.session.needsSignIn)
    await setup.session.continueWithoutAccount()
    #expect(setup.session.signOutFailed)
    #expect(setup.session.purgeFailureCount == 1)
    #expect(setup.session.lastPurgeFailure?.publicCode == "purge-signout-store")
  }

  /// Déconnexion reprise au lancement : c'est aussi une purge de déconnexion.
  @Test func aSignOutResumedAtLaunchCountsAFailedPurge() async throws {
    let setup = try await makeSetup(failures: 1, signOutPending: true)
    #expect(!setup.session.resumePendingSignOut())
    #expect(setup.session.purgeFailureCount == 1)
    #expect(setup.session.lastPurgeFailure?.publicCode == "purge-signout-store")
    #expect(setup.session.resumePendingSignOut())
    #expect(setup.session.purgeFailureCount == 0)
    #expect(setup.session.lastPurgeFailure == nil)
  }

  /// Rejeu d'un changement de compte, au lancement puis au premier plan : le bandeau vient au 3ᵉ échec, « Réessayer »
  /// réussi le retire et la synchro reprend.
  @Test func switchReplayFailuresShowTheBannerAtTheThird() async throws {
    let setup = try await makeSetup(failures: 3, switchPending: true)
    await prepareSwitch(setup)
    #expect(await setup.session.resumePendingSwitch() == false)
    #expect(setup.session.purgeFailureCount == 1)
    #expect(!setup.session.isSwitchBlocked)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(setup.session.purgeFailureCount == 2)
    #expect(!setup.session.isSwitchBlocked)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(setup.session.purgeFailureCount == 3)
    #expect(setup.session.isSwitchBlocked)
    #expect(setup.session.lastPurgeFailure == PurgeFailure(operation: .switch, step: .store))
    setup.host.steps.removeAll()
    await setup.session.retryPendingSwitch()
    #expect(setup.session.purgeFailureCount == 0)
    #expect(setup.session.lastPurgeFailure == nil)
    #expect(!setup.session.isSwitchBlocked)
    #expect(!setup.switchFlags.isPending)
    #expect(setup.host.steps.last == "resumeSync")
    #expect(try ModelContext(setup.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
  }

  /// Session illisible (Keychain verrouillé) ou compte non acquitté : étape `session`.
  @Test func aSwitchReplayFailingOnTheSessionNamesTheSessionStep() async throws {
    let setup = try await makeSetup(failures: 0, switchPending: true)
    await prepareSwitch(setup)
    await setup.gateway.setSessionReadFailure(RemoteError.keychainLocked)
    #expect(await setup.session.resumePendingSwitch() == false)
    #expect(setup.session.lastPurgeFailure?.publicCode == "purge-switch-session")
    await setup.gateway.setSessionReadFailure(nil)
    await setup.gateway.setAcknowledgeFailure(RemoteError.unauthorized)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(setup.session.purgeFailureCount == 2)
    #expect(setup.session.lastPurgeFailure?.publicCode == "purge-switch-session")
  }

  /// Drapeau `account.switch` effacé sans purge (session devenue anonyme) : le compteur repart de 0.
  @Test func theCounterIsResetWhenTheSwitchFlagIsClearedWithoutPurge() async throws {
    let setup = try await makeSetup(failures: 2, switchPending: true)
    await prepareSwitch(setup)
    #expect(await setup.session.resumePendingSwitch() == false)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(setup.session.purgeFailureCount == 2)
    await setup.gateway.setEmail(nil)
    #expect(await setup.session.replayPendingSwitch())
    #expect(!setup.switchFlags.isPending)
    #expect(setup.session.purgeFailureCount == 0)
    #expect(setup.session.lastPurgeFailure == nil)
  }

  /// Drapeau `account.switch` effacé sans purge alors que les échecs viennent de la déconnexion : le compteur garde sa
  /// valeur, l'alerte de la déconnexion ne repasse pas au message d'avant le seuil (même règle qu'Android).
  @Test func signOutFailuresKeepCountingWhenTheSwitchFlagIsClearedWithoutPurge() async throws {
    let setup = try await makeSetup(failures: 2, switchPending: true)
    await setup.session.refresh()
    await setup.session.signOut()
    await setup.session.retrySignOut()
    #expect(setup.session.purgeFailureCount == 2)
    #expect(setup.switchFlags.isPending)
    await setup.gateway.setEmail(nil)
    #expect(await setup.session.replayPendingSwitch())
    #expect(!setup.switchFlags.isPending)
    #expect(setup.session.purgeFailureCount == 2)
    #expect(setup.session.lastPurgeFailure?.operation == .signOut)
  }

  /// Drapeau `account.switch` effacé par la purge d'une déconnexion : le compteur repart de 0, le bandeau disparaît.
  @Test func theCounterIsResetWhenASignOutPurgeClearsTheSwitchFlag() async throws {
    let setup = try await makeSetup(failures: 3, switchPending: true)
    await prepareSwitch(setup)
    #expect(await setup.session.resumePendingSwitch() == false)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(await setup.session.replayPendingSwitch() == false)
    #expect(setup.session.isSwitchBlocked)
    await setup.session.refresh()
    await setup.session.signOut()
    #expect(!setup.session.signOutFailed)
    #expect(!setup.switchFlags.isPending)
    #expect(setup.session.purgeFailureCount == 0)
    #expect(!setup.session.isSwitchBlocked)
  }
}

/// Textes du ticket (#129), à l'identique sur Android.
struct PurgeHelpTextsTests {
  @Test func theTextsAreTheTicketOnes() {
    #expect(PurgeHelpTexts.signOutTitle == "La déconnexion n'a pas abouti.")
    #expect(
      PurgeHelpTexts.signOutMessage
        == "Vos listes sont peut-être encore sur cet appareil. Réessayez pour terminer la déconnexion.")
    let help =
      "Votre appareil manque peut-être d'espace. Libérez-en, puis réessayez. Si le problème continue, supprimez l'app puis réinstallez-la : vos listes restent dans votre compte."
    #expect(PurgeHelpTexts.signOutHelpMessage == help)
    #expect(PurgeHelpTexts.switchBlockedTitle == "Changement de compte inachevé")
    #expect(PurgeHelpTexts.switchBlockedMessage == "La synchronisation est arrêtée. " + help)
    #expect(PurgeHelpTexts.retry == "Réessayer")
    #expect(PurgeHelpTexts.contact == "Nous écrire")
  }
}
