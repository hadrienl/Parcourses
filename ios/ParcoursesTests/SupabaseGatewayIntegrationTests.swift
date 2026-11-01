import Foundation
import SwiftData
import Testing

@testable import Parcourses

/// Contre le Supabase local uniquement : voir `scripts/integration-test.sh`. Ignorés sinon (CI comprise).
private nonisolated enum LocalSupabase {
  static let configuration: SupabaseConfiguration? = {
    let environment = ProcessInfo.processInfo.environment
    guard
      let configuration = SupabaseConfiguration(
        url: environment["PARCOURSES_IT_URL"],
        publishableKey: environment["PARCOURSES_IT_KEY"]
      ),
      // Garde-fou : jamais d'écriture de test ailleurs qu'en local.
      configuration.url.host() == "127.0.0.1"
    else { return nil }
    return configuration
  }()
}

@Suite(.serialized, .enabled(if: LocalSupabase.configuration != nil))
struct SupabaseGatewayIntegrationTests {
  private func makeGateway(service: String = UUID().uuidString, signedIn: Bool = true) async throws -> SupabaseGateway {
    let configuration = try #require(LocalSupabase.configuration)
    let gateway = SupabaseGateway(
      configuration: configuration, store: KeychainStore(service: "app.parcourses.tests.\(service)"))
    if signedIn { try await gateway.ensureSession() }
    return gateway
  }

  @Test func withoutSessionARequestCreatesNoAccount() async throws {
    let gateway = try await makeGateway(signedIn: false)
    await #expect(throws: RemoteError.unauthorized) { try await gateway.fetchLists(updatedAfter: nil) }
    await #expect(throws: RemoteError.unauthorized) {
      try await gateway.saveList(ListUpsert(id: UUID(), name: "Sans session"))
    }
  }

  private func anyStoreId(_ gateway: SupabaseGateway) async throws -> UUID {
    let stores = try await gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 5)
    return try #require(stores.first).id
  }

  @Test func anonymousSessionSurvivesARestartThroughTheKeychain() async throws {
    let service = UUID().uuidString
    let first = try await makeGateway(service: service).ensureSession()
    let restarted = try await makeGateway(service: service).ensureSession()
    #expect(first == restarted)
    let other = try await makeGateway().ensureSession()
    #expect(other != first)
    try KeychainStore(service: "app.parcourses.tests.\(service)").removeAll()
  }

  @Test func concurrentCallsCreateASingleAccount() async throws {
    let gateway = try await makeGateway(signedIn: false)
    async let first = gateway.ensureSession()
    async let second = gateway.ensureSession()
    let (a, b) = try await (first, second)
    #expect(a == b)
  }

  @Test func listsAndItemsAreIdempotentAndPrivate() async throws {
    let gateway = try await makeGateway()
    let owner = try await gateway.ensureSession()
    let list = ListUpsert(id: UUID(), name: "Courses")
    try await gateway.saveList(list)
    try await gateway.saveList(list)
    try await gateway.saveList(ListUpsert(id: list.id, name: "Renommée"))

    let rows = try await gateway.fetchLists(updatedAfter: nil)
    #expect(rows.map(\.id) == [list.id])
    #expect(rows.first?.name == "Renommée")
    #expect(rows.first?.ownerId == owner)

    let checkedAt = Date(timeIntervalSince1970: 1_790_000_000.123)
    let item = ListItemUpsert(
      id: UUID(), listId: list.id, productId: nil, label: "Lait", quantity: "2", checkedAt: checkedAt
    )
    try await gateway.saveItem(item)
    try await gateway.saveItem(item)
    var items = try await gateway.fetchItems(updatedAfter: nil)
    #expect(items.count == 1)
    #expect(abs((items.first?.checkedAt ?? .distantPast).timeIntervalSince(checkedAt)) < 0.001)

    // Un `null` vide bien la colonne.
    try await gateway.saveItem(
      ListItemUpsert(id: item.id, listId: list.id, productId: nil, label: "Lait", quantity: nil, checkedAt: nil)
    )
    items = try await gateway.fetchItems(updatedAfter: nil)
    #expect(items.first?.quantity == nil)
    #expect(items.first?.checkedAt == nil)

    let stranger = try await makeGateway()
    #expect(try await stranger.fetchLists(updatedAfter: nil).isEmpty)
    #expect(try await stranger.fetchItems(updatedAfter: nil).isEmpty)

    let future = Date.now.addingTimeInterval(3600)
    #expect(try await gateway.fetchLists(updatedAfter: future).isEmpty)

    try await gateway.deleteItem(id: item.id)
    try await gateway.deleteItem(id: item.id)
    try await gateway.deleteList(id: list.id)
    try await gateway.deleteList(id: list.id)
    #expect(try await gateway.fetchLists(updatedAfter: nil).isEmpty)
  }

  /// Contrat hors ligne de `docs/data-model.md`, côté gateway.
  @Test func visitAndChecksFollowTheOfflineContract() async throws {
    let gateway = try await makeGateway()
    let storeId = try await anyStoreId(gateway)
    let categories = try await gateway.fetchCategories()
    let products = try await gateway.fetchProducts()
    let categorySlug = try #require(categories.first).slug
    let productId = try #require(products.first).id

    let startedAt = Date.now.addingTimeInterval(-600)
    let visit = VisitInsert(id: UUID(), storeId: storeId, listId: nil, listWasSorted: false, startedAt: startedAt)
    try await gateway.createVisit(visit)
    try await gateway.createVisit(visit)

    // Lot mixte produit et catégorie, rejoué : aucun doublon, aucune erreur.
    let batch = [
      CheckUpload(
        id: UUID(), visitId: visit.id, target: .product(productId), checkedAt: startedAt.addingTimeInterval(10)),
      CheckUpload(
        id: UUID(), visitId: visit.id, target: .category(slug: categorySlug),
        checkedAt: startedAt.addingTimeInterval(20)),
    ]
    try await gateway.insertChecks(batch)
    try await gateway.insertChecks(batch)
    try await gateway.insertChecks([])

    // 23514 : heure hors bornes.
    let tooEarly = CheckUpload(
      id: UUID(), visitId: visit.id, target: .category(slug: categorySlug),
      checkedAt: startedAt.addingTimeInterval(-3600)
    )
    await #expect(throws: RemoteError.constraint(code: "23514")) { try await gateway.insertChecks([tooEarly]) }

    // Clôture rejouable, puis 42501 sur une coche tardive.
    try await gateway.closeVisit(id: visit.id, endedAt: .now)
    try await gateway.closeVisit(id: visit.id, endedAt: .now)
    let late = CheckUpload(id: UUID(), visitId: visit.id, target: .category(slug: categorySlug), checkedAt: .now)
    await #expect(throws: RemoteError.forbidden) { try await gateway.insertChecks([late]) }
  }

  @Test func aChangedAccountStaysReported() async throws {
    let service = UUID().uuidString
    let store = KeychainStore(service: "app.parcourses.tests.\(service)")
    defer { try? store.removeAll() }
    let gateway = try await makeGateway(service: service)
    try await gateway.verifySession()
    try store.set(Data(UUID().uuidString.utf8), forKey: SupabaseGateway.lastAccountKey)

    await #expect(throws: RemoteError.accountChanged) { try await gateway.ensureSession() }
    await #expect(throws: RemoteError.accountChanged) { try await gateway.currentAccountId() }
    await #expect(throws: RemoteError.accountChanged) { try await gateway.verifySession() }
    await #expect(throws: RemoteError.accountChanged) {
      try await gateway.saveList(ListUpsert(id: UUID(), name: "Perdue"))
    }
  }

  @Test func anUnknownCategorySlugIsAnError() async throws {
    let gateway = try await makeGateway()
    let storeId = try await anyStoreId(gateway)
    let visit = VisitInsert(id: UUID(), storeId: storeId, listId: nil, listWasSorted: false, startedAt: .now)
    try await gateway.createVisit(visit)
    let check = CheckUpload(id: UUID(), visitId: visit.id, target: .category(slug: "inconnue"), checkedAt: .now)
    await #expect(throws: RemoteError.unknownCategory("inconnue")) { try await gateway.insertChecks([check]) }
  }

  /// #36 : un identifiant de `shared/categories/` a sa ligne serveur.
  @Test func aSharedCategorySlugIsAccepted() async throws {
    let gateway = try await makeGateway()
    let storeId = try await anyStoreId(gateway)
    let visit = VisitInsert(id: UUID(), storeId: storeId, listId: nil, listWasSorted: false, startedAt: .now)
    try await gateway.createVisit(visit)
    let check = CheckUpload(id: UUID(), visitId: visit.id, target: .category(slug: "dairy"), checkedAt: .now)
    try await gateway.insertChecks([check])
  }

  @Test func nearbyStoresReturnsSortedDistances() async throws {
    let gateway = try await makeGateway()
    let stores = try await gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 5)
    #expect(!stores.isEmpty)
    #expect(stores.map(\.distanceM) == stores.map(\.distanceM).sorted())
    await #expect(throws: RemoteError.rejected(code: "22023")) {
      _ = try await gateway.nearbyStores(lat: 200, lng: 0, radiusM: 1000, maxResults: 1)
    }
  }

  @Test func storeSearchFindsByNameAndTreatsInputAsText() async throws {
    let gateway = try await makeGateway()
    let known = try #require(
      try await gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 1).first)
    let found = try await gateway.searchStores(query: String(known.name.lowercased().prefix(4)), limit: 20)
    #expect(found.contains { $0.id == known.id })
    // Le jeu de départ contient « Intermarché » : la saisie sans accent le trouve.
    let unaccented = try await gateway.searchStores(query: "intermarche", limit: 20)
    #expect(!unaccented.isEmpty && unaccented.allSatisfy { $0.name.contains("Intermarché") })
    for literal in ["%%", "__", "**", "a,b)", "\"x", "\\", "+&#", "#+", "&&"] {
      #expect(try await gateway.searchStores(query: literal, limit: 20).isEmpty, "\(literal)")
    }
  }

  @Test func catalogDecodes() async throws {
    let gateway = try await makeGateway()
    #expect(try await !gateway.fetchCategories().isEmpty)
    #expect(try await !gateway.fetchProducts().isEmpty)
  }

  @Test func unreachableServerIsANetworkError() async throws {
    let configuration = try #require(SupabaseConfiguration(url: "http://127.0.0.1:9", publishableKey: "k"))
    let gateway = SupabaseGateway(
      configuration: configuration,
      store: KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")
    )
    await #expect(throws: RemoteError.network) { try await gateway.ensureSession() }
  }
}

/// Gateway réel, coupé à la demande : simule la perte de réseau de bout en bout.
private actor SwitchableGateway: RemoteGateway {
  let remote: SupabaseGateway
  var isOffline = false

  init(_ remote: SupabaseGateway) { self.remote = remote }
  func setOffline(_ value: Bool) { isOffline = value }
  private func check() throws { if isOffline { throw RemoteError.network } }

  func ensureSession(captchaToken: String?) async throws -> UUID {
    try check()
    return try await remote.ensureSession(captchaToken: captchaToken)
  }
  func sessionAccountId() async throws -> UUID {
    try check()
    return try await remote.sessionAccountId()
  }
  func acknowledgeAccount(_ id: UUID) async throws {
    try check()
    try await remote.acknowledgeAccount(id)
  }
  func serverDate() async throws -> Date? {
    try check()
    return try await remote.serverDate()
  }
  func currentAccountId() async throws -> UUID {
    try check()
    return try await remote.currentAccountId()
  }
  func verifySession() async throws {
    try check()
    try await remote.verifySession()
  }
  func saveList(_ list: ListUpsert) async throws {
    try check()
    try await remote.saveList(list)
  }
  func deleteList(id: UUID) async throws {
    try check()
    try await remote.deleteList(id: id)
  }
  func saveItem(_ item: ListItemUpsert) async throws {
    try check()
    try await remote.saveItem(item)
  }
  func deleteItem(id: UUID) async throws {
    try check()
    try await remote.deleteItem(id: id)
  }
  func createVisit(_ visit: VisitInsert) async throws {
    try check()
    try await remote.createVisit(visit)
  }
  func insertChecks(_ checks: [CheckUpload]) async throws {
    try check()
    try await remote.insertChecks(checks)
  }
  func closeVisit(id: UUID, endedAt: Date) async throws {
    try check()
    try await remote.closeVisit(id: id, endedAt: endedAt)
  }
  func visitAccess(id: UUID) async throws -> VisitAccess {
    try check()
    return try await remote.visitAccess(id: id)
  }
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] {
    try check()
    return try await remote.fetchLists(updatedAfter: updatedAfter)
  }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] {
    try check()
    return try await remote.fetchItems(updatedAfter: updatedAfter)
  }
  func fetchCategories() async throws -> [CategoryRow] {
    try check()
    return try await remote.fetchCategories()
  }
  func fetchProducts() async throws -> [RemoteProduct] {
    try check()
    return try await remote.fetchProducts()
  }
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] {
    try await remote.nearbyStores(lat: lat, lng: lng, radiusM: radiusM, maxResults: maxResults)
  }
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] {
    try await remote.searchStores(query: query, limit: limit)
  }
  func storeOrganicAisle(id: UUID) async throws -> Bool? {
    try check()
    return try await remote.storeOrganicAisle(id: id)
  }
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse {
    try check()
    return try await remote.graphSnapshot(storeId: storeId, knownVersion: knownVersion)
  }
}

private nonisolated final class ItCursors: SyncCursors, @unchecked Sendable {
  var accountId: UUID?
  var lists: Date?
  var items: Date?
  var catalog: Date?
}

/// La file complète contre le Supabase local.
@MainActor
@Suite(.serialized, .enabled(if: LocalSupabase.configuration != nil))
struct SyncEngineIntegrationTests {
  private struct Setup {
    let remote: SupabaseGateway
    let gateway: SwitchableGateway
    let engine: SyncEngine
    let context: ModelContext
    let lists: SwiftDataListRepository
    let visits: SwiftDataVisitRepository
    let container: ModelContainer
    let service: String
  }

  private func makeSetup(service: String = UUID().uuidString) async throws -> Setup {
    let configuration = try #require(LocalSupabase.configuration)
    let remote = SupabaseGateway(
      configuration: configuration, store: KeychainStore(service: "app.parcourses.tests.\(service)"))
    try await remote.ensureSession()
    let gateway = SwitchableGateway(remote)
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let categories = SwiftDataCategoryRepository(context: container.mainContext)
    try categories.seedIfNeeded()
    let engine = SyncEngine(
      gateway: gateway, container: container, cursors: ItCursors(), classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    return Setup(
      remote: remote, gateway: gateway, engine: engine, context: container.mainContext,
      lists: SwiftDataListRepository(context: container.mainContext),
      visits: SwiftDataVisitRepository(context: container.mainContext), container: container, service: service)
  }

  private func anyStoreId(_ gateway: SupabaseGateway) async throws -> UUID {
    let stores = try await gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 5)
    return try #require(stores.first).id
  }

  private func pending(_ setup: Setup) throws -> [OutboxEntry] {
    try setup.context.fetch(FetchDescriptor<OutboxEntry>())
  }

  @Test func offlineShoppingReachesTheServerOnceBack() async throws {
    let setup = try await makeSetup()
    let storeId = try #require(
      try await setup.remote.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 1).first
    ).id

    await setup.gateway.setOffline(true)
    let start = Date.now.addingTimeInterval(-60)
    let list = try setup.lists.createList(name: "Hors ligne", at: start)
    let item = try setup.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: "1", productId: nil, categoryId: "other",
      at: start)
    let visit = try setup.visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: start)
    try setup.visits.addCheck(
      visitId: visit.id, itemId: item.id, subject: .category("other"), checkedAt: start.addingTimeInterval(1))
    try setup.visits.closeVisit(id: visit.id, at: start.addingTimeInterval(2))
    await setup.engine.drain()
    #expect(try pending(setup).count == 5)

    await setup.gateway.setOffline(false)
    await setup.engine.drain(pull: true)
    #expect(try pending(setup).isEmpty)
    #expect(try await setup.remote.fetchLists(updatedAfter: nil).map(\.name) == ["Hors ligne"])
    #expect(try await setup.remote.fetchItems(updatedAfter: nil).map(\.label) == ["Lait"])
    #expect(try await setup.remote.visitAccess(id: visit.id) == .closed)
    let products = try setup.context.fetchCount(FetchDescriptor<Product>())
    #expect(products > 0)
  }

  @Test func aVisitWhoseListWasDeletedArrivesWithoutList() async throws {
    let setup = try await makeSetup()
    let storeId = try #require(
      try await setup.remote.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 1).first
    ).id
    let start = Date.now.addingTimeInterval(-60)
    let list = try setup.lists.createList(name: "Vite supprimée", at: start)
    let listId = list.id
    let visit = try setup.visits.startVisit(storeId: storeId, listId: listId, listWasSorted: false, at: start)
    try setup.lists.deleteList(id: listId, at: start)
    await setup.engine.drain()
    try setup.visits.addCheck(
      visitId: visit.id, itemId: UUID(), subject: .category("other"), checkedAt: start.addingTimeInterval(1))
    await setup.engine.drain()
    #expect(try pending(setup).isEmpty)
    #expect(try await setup.remote.visitAccess(id: visit.id) == .open)
  }

  @Test func aLateCheckIsReceivedAndAForeignVisitIsSentAgain() async throws {
    let setup = try await makeSetup()
    let storeId = try #require(
      try await setup.remote.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 1).first
    ).id
    let start = Date.now.addingTimeInterval(-60)

    // Visite déjà close côté serveur, coche encore en file : 42501, reçue.
    let list = try setup.lists.createList(name: "A", at: start)
    let closed = try setup.visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: start)
    try setup.visits.addCheck(
      visitId: closed.id, itemId: UUID(), subject: .category("other"), checkedAt: start.addingTimeInterval(1))
    await setup.engine.drain()
    try await setup.remote.closeVisit(id: closed.id, endedAt: .now)
    let late = try setup.visits.addCheck(
      visitId: closed.id, itemId: UUID(), subject: .category("other"), checkedAt: start.addingTimeInterval(2))
    await setup.engine.drain()
    #expect(try pending(setup).isEmpty)
    let lateId = late.id
    #expect(
      try setup.context.fetch(FetchDescriptor<Check>(predicate: #Predicate { $0.id == lateId })).first?.syncState
        == .synced)

    // Visite d'un autre compte, même identifiant : gardée en local, jamais marquée reçue.
    let foreign = try await makeSetup()
    let foreignVisit = VisitInsert(id: UUID(), storeId: storeId, listId: nil, listWasSorted: false, startedAt: start)
    try await foreign.remote.createVisit(foreignVisit)
    let mine = Visit(id: foreignVisit.id, storeId: storeId, listId: list.id, listWasSorted: false, startedAt: start)
    setup.context.insert(mine)
    try setup.context.save()
    let check = try setup.visits.addCheck(
      visitId: mine.id, itemId: UUID(), subject: .category("other"), checkedAt: start.addingTimeInterval(1))
    let checkId = check.id
    await setup.engine.drain()
    #expect(
      try setup.context.fetch(FetchDescriptor<Check>(predicate: #Predicate { $0.id == checkId })).first?.syncState
        == .failed)
  }

  /// Mode courses contre le vrai serveur : instantané, coche annulée, coche retenue, clôture.
  /// `scripts/integration-test.sh` publie l'instantané du magasin, puis vérifie les lignes écrites.
  @Test func aShoppingVisitReachesTheServerWithoutItsUndoneCheck() async throws {
    let variable = ProcessInfo.processInfo.environment["PARCOURSES_IT_SNAPSHOT_STORE"]
    let storeId = try #require(variable.flatMap(UUID.init(uuidString:)))
    let setup = try await makeSetup()

    #expect(try await setup.remote.graphSnapshot(storeId: UUID(), knownVersion: nil) == .none)
    let cache = GraphSnapshotCache(graphs: SwiftDataGraphRepository(context: setup.context), gateway: setup.gateway)
    let stores = SwiftDataStoreRepository(context: setup.context)
    try stores.upsertStore(
      id: storeId, name: "Magasin de test", chain: nil, address: nil, lastDistanceM: nil, organicAisle: false)

    let list = try setup.lists.createList(name: "Courses", at: .now)
    let analyzer = try EntryAnalyzer()
    for label in ["lait bio", "tomates", "pommes"] {
      let entry = analyzer.analyze(label)
      try setup.lists.addItem(
        listId: list.id, label: entry.label, normalizedName: entry.normalizedName, quantity: nil, productId: nil,
        categoryId: entry.categoryId, at: .now)
    }
    let session = ShoppingSession(
      listId: list.id, storeId: storeId, lists: setup.lists, visits: setup.visits, stores: stores,
      categories: SwiftDataCategoryRepository(context: setup.context), analyzer: analyzer, cache: cache,
      settleDelay: .milliseconds(1), undoDelay: .milliseconds(50), sendMargin: .zero)
    await session.start()
    // Le serveur (`organic_aisle` vrai) l'emporte sur le cache.
    #expect(try stores.store(id: storeId)?.organicAisle == true)
    #expect(session.knowledge == .learned(72))
    #expect(session.mode == .learned)
    let version = try #require(cache.cached(storeId: storeId)?.version)
    #expect(try await setup.remote.graphSnapshot(storeId: storeId, knownVersion: version) == .unchanged)
    let visitId = try #require(session.visitId)

    let rowNamed: (String) throws -> ShoppingRow = { label in
      try #require(session.toBuy.first { $0.label == label })
    }
    session.toggle(try rowNamed("tomates"))
    session.performUndo()
    session.toggle(try rowNamed("lait bio"))
    session.markNotFound(try rowNamed("pommes"))
    try await Task.sleep(for: .milliseconds(200))
    session.finish(keepRemaining: true)
    await setup.engine.drain()

    #expect(try pending(setup).isEmpty)
    #expect(try await setup.remote.visitAccess(id: visitId) == .closed)
    #expect(try setup.visits.checks(visitId: visitId).map(\.categoryId) == ["dairy"])
  }

  /// Vraie perte de session : un nouveau compte anonyme reçoit tout, sous de nouveaux identifiants.
  @Test func aLostSessionResendsEverythingToTheNewAccount() async throws {
    let service = UUID().uuidString
    let setup = try await makeSetup(service: service)
    let storeId = try await anyStoreId(setup.remote)
    let list = try setup.lists.createList(name: "Avant", at: .now)
    let item = try setup.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: .now)
    let visit = try setup.visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: .now)
    try setup.visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: .now)
    try setup.visits.closeVisit(id: visit.id, at: .now)
    await setup.engine.drain(pull: true)
    #expect(try pending(setup).isEmpty)
    let oldList = list.id
    let oldAccount = try await setup.remote.currentAccountId()

    // La session disparaît, le souvenir du compte reste.
    let store = KeychainStore(service: "app.parcourses.tests.\(service)")
    let known = try #require(try store.data(forKey: SupabaseGateway.lastAccountKey))
    try store.removeAll()
    try store.set(known, forKey: SupabaseGateway.lastAccountKey)
    await setup.engine.drain(pull: true)
    await setup.engine.drain(pull: true)

    #expect(try pending(setup).isEmpty)
    #expect(try await setup.remote.currentAccountId() != oldAccount)
    #expect(list.id != oldList && item.listId == list.id && visit.listId == list.id)
    #expect(try await setup.remote.fetchLists(updatedAfter: nil).map(\.id) == [list.id])
    #expect(try await setup.remote.fetchItems(updatedAfter: nil).map(\.listId) == [list.id])
    #expect(try await setup.remote.visitAccess(id: visit.id) == .closed)
    try store.removeAll()
  }

  /// Téléphone en avance de 10 min : refus réel du serveur, corrigé par l'en-tête `Date`.
  @Test func aFastPhoneReachesTheServer() async throws {
    let setup = try await makeSetup()
    #expect(abs(try #require(try await setup.remote.serverDate()).timeIntervalSinceNow) < 120)
    let engine = SyncEngine(
      gateway: setup.gateway, container: setup.container, cursors: ItCursors(),
      classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(
        now: { Date.now.addingTimeInterval(600) }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    let ahead = Date.now.addingTimeInterval(600)
    let storeId = try await anyStoreId(setup.remote)
    let list = try setup.lists.createList(name: "Avance", at: ahead)
    let item = try setup.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: ahead)
    let visit = try setup.visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: ahead)
    try setup.visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: ahead)
    try setup.visits.closeVisit(id: visit.id, at: ahead)
    await engine.drain()
    #expect(try pending(setup).isEmpty)
    // Contexte neuf : le contexte principal reçoit les écritures du moteur plus tard.
    let sent = try #require(try ModelContext(setup.container).fetch(FetchDescriptor<Visit>()).first)
    #expect(sent.syncState == .synced && sent.endSyncState == .synced)
    #expect(try await setup.remote.visitAccess(id: visit.id) == .closed)
  }

  /// Erreur serveur réelle sur une seule ligne (`scripts/integration-test.sh` pose un déclencheur sur ce nom).
  @Test func aRowFailingOnTheServerIsSetAside() async throws {
    let setup = try await makeSetup()
    let offset = Box(0.0)
    let engine = SyncEngine(
      gateway: setup.gateway, container: setup.container, cursors: ItCursors(),
      classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(
        now: { Date.now.addingTimeInterval(offset.value) }, jitter: { 1 },
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    let bad = try setup.lists.createList(name: "IT-500", at: .now)
    let good = try setup.lists.createList(name: "Saine", at: .now)
    await engine.drain()
    #expect(try await setup.remote.fetchLists(updatedAfter: nil).isEmpty)

    offset.value = SyncRetryPolicy.serverFailureGrace + 1
    await engine.kick(pull: true)
    await engine.drain()
    #expect(try await setup.remote.fetchLists(updatedAfter: nil).map(\.id) == [good.id])
    #expect(bad.syncState == .pending)
    #expect(try pending(setup).map(\.entityId) == [bad.id])
    #expect(try pending(setup).first?.attempts == 0)
  }
}

private nonisolated final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
