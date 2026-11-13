import Foundation
import Security
import Supabase
import SwiftData
import Testing

@testable import Parcourses

/// Keychain en mémoire : la purge et la doublure du serveur le partagent, comme le vrai Keychain et le SDK.
nonisolated final class MemorySecureStore: SecureStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Data] = [:]

  func data(forKey key: String) throws -> Data? { lock.withLock { values[key] } }
  func set(_ data: Data, forKey key: String) throws { lock.withLock { values[key] = data } }
  func removeValue(forKey key: String) throws { _ = lock.withLock { values.removeValue(forKey: key) } }
  func removeAll() throws {
    if failsRemoveAll { throw KeychainError(status: errSecInteractionNotAllowed) }
    lock.withLock { values.removeAll() }
  }
  /// Purge du Keychain en échec, pour une issue inconnue sans serveur.
  var failsRemoveAll: Bool {
    get { lock.withLock { failing } }
    set { lock.withLock { failing = newValue } }
  }
  private var failing = false
  var keys: Set<String> { lock.withLock { Set(values.keys) } }
}

/// Serveur simulé : comptes, session dans le Keychain partagé, et chaque écriture reçue avec son compte.
actor DeletionGateway: RemoteGateway {
  /// Ce que fait la RPC : réussir, échouer sans rien supprimer, ou supprimer puis perdre la réponse.
  enum Deletion {
    case succeed
    case failBefore(RemoteError)
    case failAfter(RemoteError)
  }

  nonisolated static let sessionKey = "session"

  private let secure: MemorySecureStore
  private let flags: any AccountDeletionFlagStore
  private(set) var accounts: Set<UUID> = []
  private(set) var deletedAccounts: Set<UUID> = []
  /// Écritures reçues : genre et compte.
  private(set) var writes: [(kind: String, account: UUID)] = []
  private(set) var calls: [String] = []
  /// `ensureSession` appelé alors que le drapeau existait : ne doit jamais arriver.
  private(set) var ensureSessionsWhileFlagged = 0
  private var deletion = Deletion.succeed
  private var verifyFailure: RemoteError?
  /// Lecture locale de la session impossible (Keychain verrouillé).
  private var localSessionFailure: RemoteError?

  init(secure: MemorySecureStore, flags: any AccountDeletionFlagStore) {
    self.secure = secure
    self.flags = flags
  }

  func setDeletion(_ value: Deletion) { deletion = value }
  func setVerifyFailure(_ value: RemoteError?) { verifyFailure = value }
  func setLocalSessionFailure(_ value: RemoteError?) { localSessionFailure = value }
  func clearCalls() { calls = [] }

  private var sessionAccount: UUID? {
    (try? secure.data(forKey: Self.sessionKey)).flatMap { $0 }.flatMap { String(bytes: $0, encoding: .utf8) }
      .flatMap(UUID.init(uuidString:))
  }

  private var lastAccount: UUID? {
    (try? secure.data(forKey: SupabaseGateway.lastAccountKey)).flatMap { $0 }
      .flatMap { String(bytes: $0, encoding: .utf8) }.flatMap(UUID.init(uuidString:))
  }

  /// Session valable : son compte existe encore. Sinon, comme le SDK après un rafraîchissement refusé, elle disparaît.
  private func liveAccount() throws -> UUID {
    guard let id = sessionAccount else { throw RemoteError.unauthorized }
    guard accounts.contains(id) else {
      try secure.removeValue(forKey: Self.sessionKey)
      throw RemoteError.unauthorized
    }
    return id
  }

  private func checkKnown(_ id: UUID) throws {
    if let known = lastAccount {
      guard known == id else { throw RemoteError.accountChanged }
    } else {
      try secure.set(Data(id.uuidString.utf8), forKey: SupabaseGateway.lastAccountKey)
    }
  }

  func ensureSession(captchaToken: String?) async throws -> UUID {
    calls.append("ensureSession")
    if flags.isDeletionPending {
      ensureSessionsWhileFlagged += 1
      // Comme `SupabaseGateway` : jamais de compte créé pendant une suppression.
      let id = try liveAccount()
      try checkKnown(id)
      return id
    }
    let id: UUID
    if let live = try? liveAccount() {
      id = live
    } else {
      id = UUID()
      accounts.insert(id)
      try secure.set(Data(id.uuidString.utf8), forKey: Self.sessionKey)
    }
    try checkKnown(id)
    return id
  }

  func currentAccountId() async throws -> UUID {
    let id = try liveAccount()
    try checkKnown(id)
    return id
  }

  func verifySession() async throws {
    calls.append("verifySession")
    _ = try liveAccount()
  }

  /// Comme le SDK : la session enregistrée, sans demander au serveur si son compte existe encore.
  func sessionAccountId() async throws -> UUID {
    guard let id = sessionAccount else { throw RemoteError.unauthorized }
    return id
  }

  func localSessionAccountId() async throws -> UUID? {
    if let localSessionFailure { throw localSessionFailure }
    return sessionAccount
  }

  /// Rafraîchissement puis compte : seule la disparition du compte prouve la suppression.
  func confirmAccountDeleted() async throws -> Bool {
    calls.append("confirmAccountDeleted")
    if let verifyFailure { throw verifyFailure }
    guard let id = sessionAccount else { throw RemoteError.unauthorized }
    return !accounts.contains(id)
  }

  func acknowledgeAccount(_ id: UUID) async throws {
    calls.append("acknowledgeAccount")
    try secure.set(Data(id.uuidString.utf8), forKey: SupabaseGateway.lastAccountKey)
  }

  func serverDate() async throws -> Date? { .now }

  func deleteAccount() async throws {
    calls.append("deleteAccount")
    guard let id = sessionAccount else { throw RemoteError.unauthorized }
    guard accounts.contains(id) else {
      // Rafraîchissement refusé (400 `refresh_token_not_found`) : le SDK oublie la session.
      try secure.removeValue(forKey: Self.sessionKey)
      throw RemoteError.accountGone(code: "refresh_token_not_found")
    }
    switch deletion {
    case .succeed:
      remove(id)
    case .failBefore(let error):
      throw error
    case .failAfter(let error):
      remove(id)
      throw error
    }
  }

  private func remove(_ id: UUID) {
    accounts.remove(id)
    deletedAccounts.insert(id)
    writes.removeAll { $0.account == id }
  }

  func signOutLocally() async throws {
    calls.append("signOutLocally")
    try secure.removeValue(forKey: Self.sessionKey)
  }

  private func write(_ kind: String) throws {
    let id = try liveAccount()
    try checkKnown(id)
    writes.append((kind, id))
  }

  func saveList(_ list: ListUpsert) async throws { try write("saveList") }
  func deleteList(id: UUID) async throws { try write("deleteList") }
  func saveItem(_ item: ListItemUpsert) async throws { try write("saveItem") }
  func deleteItem(id: UUID) async throws { try write("deleteItem") }
  func createVisit(_ visit: VisitInsert) async throws { try write("createVisit") }
  func insertChecks(_ checks: [CheckUpload]) async throws { try write("insertChecks") }
  func closeVisit(id: UUID, endedAt: Date) async throws { try write("closeVisit") }
  func visitAccess(id: UUID) async throws -> VisitAccess { .closed }
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] {
    _ = try liveAccount()
    return []
  }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] {
    _ = try liveAccount()
    return []
  }
  func fetchCategories() async throws -> [CategoryRow] { [] }
  func fetchProducts() async throws -> [RemoteProduct] { [] }
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow] {
    items.map { ResolvedProductRow(normalizedName: $0.name.lowercased(), id: nil, name: nil, categorySlug: nil) }
  }
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] { [] }
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] { [] }
  func storeOrganicAisle(id: UUID) async throws -> Bool? { nil }
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse { .none }

  func writeCount(for account: UUID) -> Int { writes.count { $0.account == account } }
}

/// Une app minimale : store en mémoire, préférences et Keychain isolés, moteur de synchronisation réel.
@MainActor
final class DeletionHarness: AccountDeletionHost {
  let container: ModelContainer
  let defaults: UserDefaults
  let secure = MemorySecureStore()
  let flags: UserDefaultsAccountDeletionFlagStore
  let gateway: DeletionGateway
  let urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
  let lists: SwiftDataListRepository
  let visits: SwiftDataVisitRepository
  private(set) var engine: SyncEngine
  var online = true
  /// Horloge de la suppression : le délai d'« Annuler » s'y mesure.
  var clock = Date(timeIntervalSince1970: 1_800_000_000)
  private(set) var hostCalls: [String] = []
  /// Calendrier de l'app : le moteur suspendu pendant la suppression ne doit plus rien envoyer.
  private(set) var engineWasSuspended = false

  init() throws {
    container = try PersistenceStack.makeContainer(storage: .inMemory)
    let suite = "tests.deletion.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suite))
    flags = UserDefaultsAccountDeletionFlagStore(defaults: defaults)
    gateway = DeletionGateway(secure: secure, flags: flags)
    lists = SwiftDataListRepository(context: container.mainContext)
    visits = SwiftDataVisitRepository(context: container.mainContext)
    try SwiftDataCategoryRepository(context: container.mainContext).seedIfNeeded()
    engine = Self.makeEngine(gateway: gateway, container: container, defaults: defaults, flags: flags)
  }

  private static func makeEngine(
    gateway: DeletionGateway, container: ModelContainer, defaults: UserDefaults,
    flags: UserDefaultsAccountDeletionFlagStore
  ) -> SyncEngine {
    SyncEngine(
      gateway: gateway, container: container, cursors: UserDefaultsSyncCursors(defaults: defaults),
      classify: { PulledItemClassification(normalizedName: $0.lowercased(), categoryId: "other") },
      dependencies: SyncEngine.Dependencies(
        jitter: { 1 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }),
      // Comme `SyncRuntime` : un moteur construit pendant une suppression naît suspendu.
      suspended: flags.isDeletionPending)
  }

  var cursors: UserDefaultsSyncCursors { UserDefaultsSyncCursors(defaults: defaults) }

  func makeDeletion(
    gateway: (any RemoteGateway)? = nil, checkpoint: @escaping (AccountDeletion.Step) throws -> Void = { _ in }
  )
    -> AccountDeletion
  {
    let deletion = AccountDeletion(
      gateway: gateway ?? self.gateway, flags: flags,
      purge: LocalDataPurge(container: container, keychain: secure, defaults: defaults, urlCache: urlCache),
      isOnline: { [unowned self] in online }, timeout: .seconds(2), now: { [unowned self] in clock },
      checkpoint: checkpoint)
    deletion.host = self
    return deletion
  }

  /// Sans serveur : build sans Supabase.
  func makeLocalDeletion() -> AccountDeletion {
    let deletion = AccountDeletion(
      gateway: nil, flags: flags,
      purge: LocalDataPurge(container: container, keychain: secure, defaults: defaults, urlCache: urlCache),
      isOnline: { false })
    deletion.host = self
    return deletion
  }

  /// Relance de l'app : moteur neuf, suspendu si le drapeau est là.
  func relaunch() {
    engine = Self.makeEngine(gateway: gateway, container: container, defaults: defaults, flags: flags)
  }

  func suspendSync() async {
    hostCalls.append("suspendSync")
    await engine.suspend()
    engineWasSuspended = await engine.isSuspended
  }

  func resumeSync() {
    hostCalls.append("resumeSync")
    let engine = engine
    Task { await engine.resume() }
  }

  func stopSync() async {
    hostCalls.append("stopSync")
    await engine.stop()
  }

  func endShopping() { hostCalls.append("endShopping") }

  /// Plus de `cancelDelay` depuis le dernier envoi.
  func letCancelDelayPass() { clock.addTimeInterval(AccountDeletion.cancelDelay + 1) }

  func restart() {
    hostCalls.append("restart")
    relaunch()
  }

  // MARK: - Données

  /// Liste, article, visite close avec une coche, magasin récent, instantané, produit, curseurs, cache HTTP.
  func seedEverything() throws {
    let now = Date.now
    let list = try lists.createList(name: "Courses", at: now)
    let item = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: now)
    let storeId = UUID()
    let visit = try visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: now)
    try visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: now)
    try visits.closeVisit(id: visit.id, at: now)
    let context = container.mainContext
    try SwiftDataStoreRepository(context: context).upsertStore(
      id: storeId, name: "Leclerc Auch", chain: nil, address: "Auch", lastDistanceM: 20, organicAisle: false)
    try SwiftDataGraphRepository(context: context).saveSnapshot(
      storeId: storeId, snapshotVersion: 1, paramsVersion: 1, confidenceQ: 0, payload: Data("{}".utf8), at: now)
    context.insert(Product(id: UUID(), name: "Lait demi-écrémé", normalizedName: "lait demi-ecreme"))
    try context.save()
    let cursors = cursors
    cursors.catalog = now
    defaults.set("visite", forKey: "liveActivityDismissedVisitId")
    let url = Self.cachedURL
    urlCache.storeCachedResponse(
      CachedURLResponse(
        response: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data: Data("x".utf8)
      ),
      for: URLRequest(url: url))
    // Le cache est bien rempli : sa purge se vérifie ensuite.
    #expect(isResponseCached)
  }

  static let cachedURL = URL(string: "https://example.org/a")!

  var isResponseCached: Bool { urlCache.cachedResponse(for: URLRequest(url: Self.cachedURL)) != nil }

  /// Compte connecté et données reçues par le serveur.
  @discardableResult
  func signInAndSync() async throws -> UUID {
    let id = try await gateway.ensureSession(captchaToken: nil)
    await engine.drain(pull: true)
    return id
  }

  func count<Model: PersistentModel>(_ type: Model.Type) throws -> Int {
    try ModelContext(container).fetchCount(FetchDescriptor<Model>())
  }

  /// Rien du compte supprimé ne reste : seules les catégories, amorcées à nouveau, et rien d'autre.
  func expectPurged(sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try count(ShoppingList.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(ListItem.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(Visit.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(Check.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(OutboxEntry.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(Store.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(GraphSnapshot.self) == 0, sourceLocation: sourceLocation)
    #expect(try count(Product.self) == 0, sourceLocation: sourceLocation)
    let seeded = try CategorySeed.bundled().categories.count
    #expect(try count(SchemaV1.Category.self) == seeded, sourceLocation: sourceLocation)
    #expect(try count(CategorySeedState.self) == 1, sourceLocation: sourceLocation)
    let categories = try ModelContext(container).fetch(FetchDescriptor<SchemaV1.Category>())
    #expect(categories.allSatisfy { $0.remoteId == nil }, sourceLocation: sourceLocation)
    for key in UserDefaultsSyncCursors.keys {
      #expect(defaults.object(forKey: key) == nil, "\(key)", sourceLocation: sourceLocation)
    }
    #expect(defaults.object(forKey: "liveActivityDismissedVisitId") == nil, sourceLocation: sourceLocation)
    #expect(!isResponseCached, sourceLocation: sourceLocation)
    #expect(flags.load() == nil, sourceLocation: sourceLocation)
  }

  /// Données de départ intactes : rien n'a été effacé.
  func expectIntact(sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try count(ShoppingList.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(ListItem.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(Visit.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(Check.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(Store.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(GraphSnapshot.self) == 1, sourceLocation: sourceLocation)
    #expect(try count(Product.self) == 1, sourceLocation: sourceLocation)
    #expect(secure.keys.contains(SupabaseGateway.lastAccountKey), sourceLocation: sourceLocation)
  }
}

@MainActor
@Suite(.serialized)
struct AccountDeletionTests {
  @Test func deletesTheServerAccountThenPurgesTheDeviceAndAdoptsAFreshAccount() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    #expect(await app.gateway.writeCount(for: old) > 0)

    let deletion = app.makeDeletion()
    await deletion.delete()

    #expect(deletion.status == .deleted)
    #expect(app.hostCalls == ["suspendSync", "endShopping", "stopSync"])
    #expect(app.engineWasSuspended)
    #expect(await app.engine.isStopped)
    #expect(await app.gateway.deletedAccounts == [old])
    try app.expectPurged()
    // Nouveau compte adopté sans reprise : il devient le dernier compte connu, et la session lui appartient.
    let accounts = await app.gateway.accounts
    #expect(accounts.count == 1)
    let new = try #require(accounts.first)
    #expect(new != old)
    #expect(try app.secure.data(forKey: SupabaseGateway.lastAccountKey) == Data(new.uuidString.utf8))
    #expect(await app.gateway.ensureSessionsWhileFlagged == 0)

    deletion.acknowledge()
    #expect(deletion.status == .idle)
    #expect(app.hostCalls.last == "restart")
  }

  /// Le risque du §2 : un nouveau compte ne reçoit rien, ni par la file, ni par `AccountRekey`.
  @Test func theNewAccountReceivesNoneOfTheDeletedData() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    // Des données encore en file au moment de la suppression.
    let pending = try app.lists.createList(name: "Pas encore envoyée", at: .now)
    _ = try app.lists.addItem(
      listId: pending.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "dairy",
      at: .now)
    #expect(try app.count(OutboxEntry.self) > 0)

    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .deleted)
    deletion.acknowledge()

    // Lancement de l'app reconstruite : connexion puis passes complètes, réconciliation de la file comprise.
    let new = try await app.gateway.ensureSession(captchaToken: nil)
    #expect(new != old)
    await app.engine.drain(pull: true)
    await app.engine.drain(pull: true)
    #expect(await app.gateway.writeCount(for: new) == 0)
    #expect(await app.gateway.calls.contains("acknowledgeAccount") == false)
    #expect(try app.count(OutboxEntry.self) == 0)
    #expect(try app.count(ShoppingList.self) == 0)
    #expect(app.cursors.accountId == new)
  }

  @Test func offlineTouchesNothing() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    await app.gateway.clearCalls()
    app.online = false

    let deletion = app.makeDeletion()
    await deletion.delete()

    #expect(deletion.status == .failed(.offline))
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls.isEmpty)
    #expect(await app.gateway.calls.isEmpty)
    try app.expectIntact()
    deletion.acknowledge()
    #expect(deletion.status == .idle)
  }

  /// Premier envoi : un refus définitif, ou une requête qui n'a pas quitté l'appareil, prouvent que rien n'a été
  /// supprimé. Le drapeau part et la synchronisation reprend.
  @Test(arguments: [
    (RemoteError.rejected(code: RemoteError.functionNotFoundCode), AccountDeletionError.refused),
    (.rejected(code: "22023"), .refused), (.server(code: "404"), .refused), (.notSent, .offline),
  ])
  func aFirstAttemptRefusalKeepsEverythingAndResumesSync(error: RemoteError, expected: AccountDeletionError)
    async throws
  {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(error))

    let deletion = app.makeDeletion()
    await deletion.delete()

    #expect(deletion.status == .failed(expected))
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls == ["suspendSync", "endShopping", "resumeSync"])
    #expect(await app.gateway.calls.contains("confirmAccountDeleted") == false)
    #expect(await app.gateway.accounts == [old])
    try app.expectIntact()
  }

  /// Après un doute, un envoi précédent a peut-être abouti : le refus passe par la vérification, et le drapeau ne part
  /// que si le compte existe.
  @Test(arguments: [
    (RemoteError.rejected(code: RemoteError.functionNotFoundCode), AccountDeletionError.refused),
    (.notSent, .offline),
  ])
  func aRefusalAfterADoubtIsVerifiedFirst(error: RemoteError, expected: AccountDeletionError) async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(.network))
    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))

    await app.gateway.clearCalls()
    await app.gateway.setDeletion(.failBefore(error))
    await deletion.retry()

    #expect(await app.gateway.calls == ["deleteAccount", "confirmAccountDeleted"])
    #expect(deletion.status == .failed(expected))
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls.last == "resumeSync")
    #expect(await app.gateway.accounts == [old])
    try app.expectIntact()
  }

  /// Réponse perdue (coupure, 5xx, verrou du calcul du graphe, délai de requête) après la suppression : le compte
  /// est introuvable, la purge a lieu.
  @Test(arguments: [RemoteError.network, .server(code: "503"), .server(code: "55P03"), .server(code: "57014")])
  func aLostResponseIsResolvedByVerifyingTheAccount(error: RemoteError) async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failAfter(error))

    let deletion = app.makeDeletion()
    await deletion.delete()

    #expect(deletion.status == .deleted)
    #expect(await app.gateway.calls.filter { $0 == "deleteAccount" }.count == 1)
    #expect(await app.gateway.calls.contains("confirmAccountDeleted"))
    #expect(await app.gateway.deletedAccounts == [old])
    try app.expectPurged()
  }

  /// RPC réussie sans réponse, vérification muette, puis relance : le rafraîchissement est refusé (400
  /// `refresh_token_not_found`), preuve de la suppression, et la purge a lieu.
  @Test func aSuccessWhoseAnswerWasLostIsProvenAtRelaunch() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failAfter(.network))
    await app.gateway.setVerifyFailure(.network)
    let first = app.makeDeletion()
    await first.delete()
    #expect(first.status == .failed(.unknown))
    try app.expectIntact()

    await app.gateway.setVerifyFailure(nil)
    app.relaunch()
    let relaunched = app.makeDeletion()
    await relaunched.resumeIfNeeded()

    #expect(relaunched.status == .deleted)
    #expect(await app.gateway.calls.filter { $0 == "deleteAccount" }.count == 2)
    #expect(await app.gateway.deletedAccounts == [old])
    try app.expectPurged()
    #expect(await app.gateway.ensureSessionsWhileFlagged == 0)
  }

  /// Doute et compte toujours là : drapeau gardé, rien d'effacé, synchronisation toujours arrêtée ; « Réessayer »
  /// finit le travail.
  @Test(arguments: [RemoteError.network, .server(code: "55P03"), .server(code: "57014"), .forbidden])
  func aDoubtWithTheAccountStillThereOffersRetry(error: RemoteError) async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(error))

    let deletion = app.makeDeletion()
    await deletion.delete()

    #expect(deletion.status == .failed(.unknown))
    #expect(app.flags.load() == AccountDeletionFlag(accountId: old, phase: .requested, rpcAttempted: true))
    #expect(!app.hostCalls.contains("resumeSync"))
    #expect(await app.engine.isSuspended)
    try app.expectIntact()

    await app.gateway.setDeletion(.succeed)
    await deletion.retry()
    #expect(deletion.status == .deleted)
    try app.expectPurged()
    #expect(await app.gateway.ensureSessionsWhileFlagged == 0)
  }

  /// « Annuler » attend `cancelDelay` après l'envoi : une RPC en retard pourrait encore supprimer le compte.
  @Test func cancellingAfterADoubtWaitsThenKeepsTheDataWhenTheAccountStillExists() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(.network))

    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))
    let revision = deletion.revision

    await deletion.cancel()
    #expect(deletion.status == .failed(.unknown))
    #expect(deletion.isCancelDeferred)
    #expect(deletion.revision > revision)
    #expect(app.flags.isDeletionPending)
    #expect(!app.hostCalls.contains("resumeSync"))

    app.letCancelDelayPass()
    await deletion.cancel()
    #expect(deletion.status == .idle)
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls.last == "resumeSync")
    #expect(await app.gateway.accounts == [old])
    try app.expectIntact()
  }

  /// Sans réponse du serveur à la vérification, « Annuler » ne prend aucun risque : le compte a peut-être disparu, et
  /// reprendre la synchronisation renverrait tout vers un nouveau compte.
  @Test func cancellingWithoutAnAnswerKeepsTheDeletionPending() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(.network))
    await app.gateway.setVerifyFailure(.network)

    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))
    app.letCancelDelayPass()
    await deletion.cancel()

    #expect(deletion.status == .failed(.unknown))
    #expect(deletion.isCancelDeferred)
    #expect(app.flags.isDeletionPending)
    #expect(!app.hostCalls.contains("resumeSync"))
    try app.expectIntact()
  }

  @Test func cancellingWhenTheAccountIsGoneFinishesTheDeletion() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    // Réponse perdue, et la vérification aussi : le doute reste.
    await app.gateway.setDeletion(.failAfter(.network))
    await app.gateway.setVerifyFailure(.network)

    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))
    await app.gateway.setVerifyFailure(nil)
    app.letCancelDelayPass()
    await deletion.cancel()

    #expect(deletion.status == .deleted)
    try app.expectPurged()
  }

  /// Sans session sur l'appareil, aucune preuve n'est possible : « Annuler » rend ses données à la personne.
  @Test func cancellingWithoutALocalSessionKeepsTheData() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    await app.gateway.setDeletion(.failBefore(.network))
    let deletion = app.makeDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))
    try app.secure.removeValue(forKey: DeletionGateway.sessionKey)
    await app.gateway.clearCalls()

    app.letCancelDelayPass()
    await deletion.cancel()

    #expect(deletion.status == .idle)
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls.last == "resumeSync")
    #expect(await app.gateway.calls.isEmpty)
    try app.expectIntact()
  }

  nonisolated static let interruptions: [AccountDeletion.Step] =
    [.flagged, .syncSuspended, .shoppingEnded, .serverDeleted]
    + LocalDataPurge.Step.allCases.map { AccountDeletion.Step.purge($0) }
    + [.signedOut, .flagCleared, .sessionCreated]

  /// Processus tué après chaque étape, puis relancé : même état final, et jamais `ensureSession` tant que le drapeau
  /// existe.
  @Test(arguments: interruptions)
  func anInterruptionAfterAnyStepEndsTheSame(step: AccountDeletion.Step) async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()

    let interrupted = app.makeDeletion { if $0 == step { throw CancellationError() } }
    await interrupted.delete()
    #expect(interrupted.status == .deleting)

    // Relance : moteur neuf, suspendu si le drapeau est resté ; même logique que `AppModel`.
    app.relaunch()
    let relaunched = app.makeDeletion()
    if relaunched.isPending {
      #expect(await app.engine.isSuspended)
      await relaunched.resumeIfNeeded()
      #expect(relaunched.status == .deleted)
      // Message lu : l'app repart sur un moteur neuf.
      relaunched.acknowledge()
    } else {
      // Drapeau déjà effacé : lancement normal, connexion comprise.
      _ = try await app.gateway.ensureSession(captchaToken: nil)
    }

    try app.expectPurged()
    #expect(await app.gateway.deletedAccounts == [old])
    let accounts = await app.gateway.accounts
    #expect(accounts.count == 1)
    #expect(!accounts.contains(old))
    #expect(await app.gateway.ensureSessionsWhileFlagged == 0)
    await app.engine.drain(pull: true)
    for account in accounts { #expect(await app.gateway.writeCount(for: account) == 0) }
  }

  /// Relance sans session sur l'appareil : purge de l'appareil seulement, sans appeler la RPC, et message distinct.
  @Test func relaunchWithoutASessionPurgesOnlyTheDevice() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let old = try await app.signInAndSync()
    let interrupted = app.makeDeletion { if $0 == .shoppingEnded { throw CancellationError() } }
    await interrupted.delete()
    try app.secure.removeValue(forKey: DeletionGateway.sessionKey)
    await app.gateway.clearCalls()

    app.relaunch()
    let relaunched = app.makeDeletion()
    await relaunched.resumeIfNeeded()

    #expect(relaunched.status == .deletedFromDevice)
    #expect(await app.gateway.calls.contains("deleteAccount") == false)
    #expect(await app.gateway.accounts.contains(old))
    try app.expectPurged()
  }

  /// Relance avec la session d'un autre compte que celui du drapeau : comme sans session.
  @Test func relaunchWithAnotherAccountsSessionPurgesOnlyTheDevice() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    let current = try await app.signInAndSync()
    app.flags.save(AccountDeletionFlag(accountId: UUID(), phase: .requested, rpcAttempted: true))

    app.relaunch()
    let relaunched = app.makeDeletion()
    await relaunched.resumeIfNeeded()

    #expect(relaunched.status == .deletedFromDevice)
    #expect(await app.gateway.calls.contains("deleteAccount") == false)
    #expect(await app.gateway.accounts.contains(current))
    try app.expectPurged()
  }

  /// Relance avec le serveur injoignable : le drapeau reste, rien n'est effacé, la synchronisation reste arrêtée.
  @Test func relaunchWhileTheServerIsUnreachableStaysPending() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    let interrupted = app.makeDeletion { if $0 == .flagged { throw CancellationError() } }
    await interrupted.delete()
    await app.gateway.setDeletion(.failBefore(.network))
    await app.gateway.setVerifyFailure(.network)

    app.relaunch()
    let relaunched = app.makeDeletion()
    await relaunched.resumeIfNeeded()

    #expect(relaunched.status == .failed(.unknown))
    #expect(app.flags.isDeletionPending)
    #expect(await app.engine.isSuspended)
    try app.expectIntact()
    #expect(await app.gateway.ensureSessionsWhileFlagged == 0)
  }

  /// Keychain illisible à la reprise : doute, jamais refus ni purge.
  @Test func aLockedKeychainAtRelaunchIsADoubt() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try await app.signInAndSync()
    let interrupted = app.makeDeletion { if $0 == .flagged { throw CancellationError() } }
    await interrupted.delete()
    await app.gateway.setLocalSessionFailure(.keychainLocked)
    await app.gateway.clearCalls()

    app.relaunch()
    let relaunched = app.makeDeletion()
    await relaunched.resumeIfNeeded()

    #expect(relaunched.status == .failed(.unknown))
    #expect(app.flags.isDeletionPending)
    #expect(await app.gateway.calls.isEmpty)
    try app.expectIntact()
  }

  /// Build sans Supabase : l'appareil seulement, sans exiger de réseau.
  @Test func withoutServerOnlyTheDeviceIsPurged() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try app.secure.set(Data("x".utf8), forKey: "availability-sentinel")

    let deletion = app.makeLocalDeletion()
    #expect(!deletion.deletesServerData)
    await deletion.delete()

    #expect(deletion.status == .deleted)
    try app.expectPurged()
    #expect(app.secure.keys.isEmpty)
  }

  /// Build sans Supabase, purge en échec : « Annuler » garde ce qui reste, sans relancer la purge.
  @Test func withoutServerCancellingDoesNotPurgeAgain() async throws {
    let app = try DeletionHarness()
    try app.seedEverything()
    try app.secure.set(Data("x".utf8), forKey: "availability-sentinel")
    app.secure.failsRemoveAll = true

    let deletion = app.makeLocalDeletion()
    await deletion.delete()
    #expect(deletion.status == .failed(.unknown))
    await deletion.cancel()

    #expect(deletion.status == .idle)
    #expect(app.flags.load() == nil)
    #expect(app.hostCalls.last == "resumeSync")
    #expect(app.secure.keys == ["availability-sentinel"])
  }

  @Test func theFlagSurvivesARelaunchAndAnUnreadableFlagCountsAsPending() throws {
    let defaults = try #require(UserDefaults(suiteName: "tests.flag.\(UUID().uuidString)"))
    let flags = UserDefaultsAccountDeletionFlagStore(defaults: defaults)
    let account = UUID()
    flags.save(AccountDeletionFlag(accountId: account, phase: .serverDeleted))
    #expect(
      UserDefaultsAccountDeletionFlagStore(defaults: defaults).load()
        == .init(accountId: account, phase: .serverDeleted))
    defaults.set(Data("illisible".utf8), forKey: AccountDeletionFlag.key)
    #expect(flags.load() == AccountDeletionFlag(accountId: nil, phase: .requested, rpcAttempted: true))
    // Sans `rpcAttempted` : la prudence l'emporte, l'envoi est supposé fait.
    defaults.set(Data(#"{"phase":"requested"}"#.utf8), forKey: AccountDeletionFlag.key)
    #expect(flags.load() == AccountDeletionFlag(accountId: nil, phase: .requested, rpcAttempted: true))
    flags.clear()
    #expect(!flags.isDeletionPending)
  }
}

/// Classement des réponses du serveur pendant une suppression (contrat 68.1, relecture de 68.2).
struct AccountDeletionClassificationTests {
  private static let url = URL(string: "http://127.0.0.1")!

  private func authError(_ code: ErrorCode, status: Int) -> AuthError {
    .api(
      message: "m", errorCode: code, underlyingData: Data(),
      underlyingResponse: HTTPURLResponse(url: Self.url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  @Test(arguments: [
    (RemoteError.rejected(code: "PGRST202"), true), (.rejected(code: "22023"), true),
    (.constraint(code: "23514"), true),
    (.server(code: "404"), true), (.server(code: "55P03"), false), (.server(code: "57014"), false),
    (.server(code: "500"), false), (.server(code: "429"), false), (.server(code: "403"), false), (.forbidden, false),
    (.unauthorized, false), (.network, false), (.unexpected, false), (.keychainLocked, false), (.notSent, false),
    (.accountGone(code: "user_not_found"), false),
  ])
  func onlyADefinitiveRefusalStopsTheDeletion(error: RemoteError, refused: Bool) {
    #expect(error.isDefinitiveDeletionRefusal == refused)
  }

  @Test func temporaryRPCFailuresAreServerErrors() {
    #expect(SupabaseGateway.classify(PostgrestError(code: "55P03", message: "m")) == .server(code: "55P03"))
    #expect(SupabaseGateway.classify(PostgrestError(code: "57014", message: "m")) == .server(code: "57014"))
  }

  /// Seuls trois codes GoTrue prouvent la suppression ; leur code est gardé.
  @Test func onlyThreeAuthCodesProveTheDeletion() {
    for (code, status) in [(ErrorCode.refreshTokenNotFound, 400), (.userNotFound, 403), (.sessionNotFound, 403)] {
      #expect(
        SupabaseGateway.classifyForDeletion(authError(code, status: status)) == .accountGone(code: code.rawValue))
    }
    // Autres refus : doute, jamais preuve.
    #expect(SupabaseGateway.classifyForDeletion(authError(ErrorCode("bad_jwt"), status: 403)) == .unauthorized)
    #expect(SupabaseGateway.classifyForDeletion(authError(ErrorCode("no_authorization"), status: 401)) == .unauthorized)
    #expect(SupabaseGateway.classifyForDeletion(AuthError.sessionMissing) == .unauthorized)
    #expect(SupabaseGateway.deletionProofCode(AuthError.sessionMissing) == nil)
    #expect(SupabaseGateway.classifyForDeletion(KeychainError(status: errSecItemNotFound)) == .unauthorized)
    #expect(SupabaseGateway.classifyForDeletion(KeychainError(status: errSecInteractionNotAllowed)) == .keychainLocked)
    // Le moteur de synchronisation garde son classement : une session perdue reste `unauthorized`.
    #expect(SupabaseGateway.classify(authError(.userNotFound, status: 403) as any Error) == .unauthorized)
  }

  /// Requête jamais partie : `notSent`. Délai dépassé ou connexion perdue : la requête a pu arriver, doute.
  @Test(arguments: [
    (URLError.Code.notConnectedToInternet, RemoteError.notSent), (.cannotFindHost, .notSent),
    (.cannotConnectToHost, .notSent), (.dnsLookupFailed, .notSent), (.dataNotAllowed, .notSent),
    (.internationalRoamingOff, .notSent), (.timedOut, .network), (.networkConnectionLost, .network),
    (.secureConnectionFailed, .network),
  ])
  func onlyUnsentRequestsCountAsOffline(code: URLError.Code, expected: RemoteError) {
    #expect(SupabaseGateway.classifyForDeletion(URLError(code)) == expected)
    // Hors suppression, tout reste `network`.
    #expect(SupabaseGateway.classify(URLError(code)) == .network)
  }
}

/// Suspension du moteur (#68 §5.3) : aucune passe, aucun réveil, puis reprise.
@MainActor
struct SyncEngineSuspensionTests {
  @Test func aSuspendedEngineSendsNothingUntilResumed() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    await harness.engine.suspend()
    await harness.engine.drain(pull: true)
    await harness.engine.kick(pull: true)
    #expect(await harness.gateway.calls.isEmpty)
    #expect(try harness.entries().count > 0)

    await harness.engine.resume()
    await harness.engine.drain()
    #expect(await harness.gateway.calls.contains("saveList"))
  }

  @Test func anEngineBornSuspendedDoesNotStart() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    let engine = SyncEngine(
      gateway: harness.gateway, container: harness.container, cursors: harness.cursors,
      classify: { PulledItemClassification(normalizedName: $0, categoryId: "other") }, suspended: true)
    await engine.drain(pull: true)
    #expect(await harness.gateway.calls.isEmpty)
    #expect(await engine.isSuspended)
  }

  /// Le moteur du compte supprimé : une connexion tardive (`resume`) ne le relance pas.
  @Test func aStoppedEngineNeverResumes() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    await harness.engine.stop()
    await harness.engine.resume()
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.isEmpty)
    #expect(await harness.engine.isStopped)
  }

  /// Une passe en cours est interrompue et attendue : après `suspend()`, plus aucun appel ne part.
  @Test func suspendWaitsForTheRunningPass() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    let gate = AsyncGate()
    await harness.gateway.setAfterSaveList { await gate.wait() }
    await harness.engine.kick()
    // Attente de l'envoi de la liste, retenu par la porte.
    while await harness.gateway.calls.contains("saveList") == false { await Task.yield() }
    let suspension = Task { await harness.engine.suspend() }
    await gate.open()
    await suspension.value
    let calls = await harness.gateway.calls.count
    try await Task.sleep(for: .milliseconds(50))
    #expect(await harness.gateway.calls.count == calls)
    #expect(await harness.engine.isSuspended)
  }
}

/// Porte asynchrone : retient une tâche jusqu'à `open()`.
actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}
