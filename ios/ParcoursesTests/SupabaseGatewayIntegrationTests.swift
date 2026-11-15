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
    #expect(try await gateway.insertItem(item))
    #expect(try await gateway.insertItem(item) == false)
    var items = try await gateway.fetchItems(updatedAfter: nil)
    #expect(items.count == 1)
    #expect(abs((items.first?.checkedAt ?? .distantPast).timeIntervalSince(checkedAt)) < 0.001)
    #expect(items.first?.updatedBy == owner)

    // Un `null` vide bien la colonne, et seules les colonnes demandées partent.
    let cleared = ListItemUpsert(
      id: item.id, listId: list.id, productId: nil, label: "Autre", quantity: nil, checkedAt: nil)
    #expect(
      try await gateway.updateItem(
        id: item.id,
        fields: ListItemFields(values: cleared, columns: [ListItemFields.quantity, ListItemFields.checkedAt])))
    items = try await gateway.fetchItems(updatedAfter: nil)
    #expect(items.first?.quantity == nil)
    #expect(items.first?.checkedAt == nil)
    #expect(items.first?.label == "Lait")
    #expect(try await gateway.fetchItems(listId: list.id).map(\.id) == [item.id])
    #expect(try await gateway.fetchItemIds(listId: list.id) == [item.id])
    #expect(try await gateway.accessibleListIds() == [list.id])

    let stranger = try await makeGateway()
    #expect(try await stranger.fetchLists(updatedAfter: nil).isEmpty)
    #expect(try await stranger.fetchItems(updatedAfter: nil).isEmpty)

    let future = Date.now.addingTimeInterval(3600)
    #expect(try await gateway.fetchLists(updatedAfter: future).isEmpty)

    let before = Date.now.addingTimeInterval(-60)
    #expect(try await gateway.deleteItem(id: item.id))
    #expect(try await gateway.deleteItem(id: item.id) == false)
    // Pierre tombale lisible, par date comme par identifiant ; une mise à jour ne touche plus rien.
    #expect(try await gateway.fetchTombstones(after: before).map(\.id).contains(item.id))
    #expect(try await gateway.fetchTombstones(ids: [item.id, UUID()]).map(\.id) == [item.id])
    #expect(try await stranger.fetchTombstones(ids: [item.id]).isEmpty)
    #expect(
      try await gateway.updateItem(id: item.id, fields: ListItemFields(values: item, columns: ListItemFields.all))
        == false)
    // Renvoyée, l'insertion ne ressuscite pas l'article, et le dit.
    #expect(try await gateway.insertItem(item) == false)
    #expect(try await gateway.fetchItemIds(listId: list.id).isEmpty)
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

  @Test func freeLabelsResolveToSharedProducts() async throws {
    let gateway = try await makeGateway()
    let rows = try await gateway.resolveProducts([
      ProductResolutionRequest(name: "Baguette", categorySlug: "frozen"),
      // Nom fixe : créé au premier passage, repris ensuite.
      ProductResolutionRequest(name: "Produit de test d'intégration", categorySlug: "other"),
      ProductResolutionRequest(name: "Graines de test bio", categorySlug: "bio"),
    ])
    #expect(rows.map(\.normalizedName) == ["baguette", "produit de test d'integration", "graines de test bio"])
    #expect(rows.map { $0.id != nil } == [true, true, false])
    #expect(rows.map(\.categorySlug) == ["bakery", "other", nil])
    let again = try await makeGateway().resolveProducts([
      ProductResolutionRequest(name: "produit de test d'integration", categorySlug: "snacks")
    ])
    #expect(again.first?.id == rows[1].id)
    await #expect(throws: RemoteError.rejected(code: "22023")) {
      _ = try await gateway.resolveProducts(
        (0...100).map { ProductResolutionRequest(name: "x\($0)", categorySlug: nil) })
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
  func deleteAccount() async throws {
    try check()
    try await remote.deleteAccount()
  }
  func signOutLocally() async throws {
    try await remote.signOutLocally()
  }
  func localSessionAccountId() async throws -> UUID? {
    try await remote.localSessionAccountId()
  }
  func confirmAccountDeleted() async throws -> Bool {
    try check()
    return try await remote.confirmAccountDeleted()
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
  func insertItem(_ item: ListItemUpsert) async throws -> Bool {
    try check()
    return try await remote.insertItem(item)
  }
  func updateItem(id: UUID, fields: ListItemFields) async throws -> Bool {
    try check()
    return try await remote.updateItem(id: id, fields: fields)
  }
  func deleteItem(id: UUID) async throws -> Bool {
    try check()
    return try await remote.deleteItem(id: id)
  }
  func fetchItems(listId: UUID) async throws -> [ListItemRow] {
    try check()
    return try await remote.fetchItems(listId: listId)
  }
  func fetchItemIds(listId: UUID) async throws -> [UUID] {
    try check()
    return try await remote.fetchItemIds(listId: listId)
  }
  func accessibleListIds() async throws -> [UUID] {
    try check()
    return try await remote.accessibleListIds()
  }
  func fetchTombstones(after: Date?) async throws -> [TombstoneRow] {
    try check()
    return try await remote.fetchTombstones(after: after)
  }
  func fetchTombstones(ids: [UUID]) async throws -> [TombstoneRow] {
    try check()
    return try await remote.fetchTombstones(ids: ids)
  }
  func accountEmail() async throws -> String? { try await remote.accountEmail() }
  func linkEmail(_ email: String) async throws {
    try check()
    try await remote.linkEmail(email)
  }
  func signInWithEmail(_ email: String) async throws {
    try check()
    try await remote.signInWithEmail(email)
  }
  func verifyCode(email: String, code: String, purpose: EmailCodePurpose) async throws -> VerifiedCode {
    try check()
    return try await remote.verifyCode(email: email, code: code, purpose: purpose)
  }
  func displayName() async throws -> String? {
    try check()
    return try await remote.displayName()
  }
  func setDisplayName(_ name: String) async throws {
    try check()
    try await remote.setDisplayName(name)
  }
  func signOut() async throws { try await remote.signOut() }
  func deleteAccount(accessToken: String) async throws {
    try check()
    try await remote.deleteAccount(accessToken: accessToken)
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
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow] {
    try check()
    return try await remote.resolveProducts(items)
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
  var tombstones: Date?
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
    // L'article saisi librement a reçu son produit avant l'envoi : la coche le désigne.
    let checks = try setup.visits.checks(visitId: visitId)
    #expect(checks.count == 1)
    #expect(checks.allSatisfy { $0.productId != nil && $0.categoryId == nil })
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
    // Reçue et close par l'ancien compte : pas renvoyée, le graphe ne l'apprend pas deux fois.
    #expect(try await setup.remote.visitAccess(id: visit.id) == .notVisible)
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

/// Suspend le moteur comme le fait `AppModel` ; le reste n'a pas de sens sans écran.
@MainActor
private final class IntegrationDeletionHost: AccountDeletionHost {
  let engine: SyncEngine
  init(engine: SyncEngine) { self.engine = engine }
  func suspendSync() async { await engine.suspend() }
  func resumeSync() {
    let engine = engine
    Task { await engine.resume() }
  }
  func stopSync() async { await engine.stop() }
  func endShopping() {
    // Pas de Live Activity ni de mode courses dans ce test.
  }
  func restart() {
    // Le test reconstruit lui-même le moteur.
  }
}

/// Suppression du compte de bout en bout contre le Supabase local (#68, lot 68.2).
@MainActor
@Suite(.serialized, .enabled(if: LocalSupabase.configuration != nil))
struct AccountDeletionIntegrationTests {
  private struct Device {
    let gateway: SupabaseGateway
    let keychain: KeychainStore
    let defaults: UserDefaults
    let flags: UserDefaultsAccountDeletionFlagStore
  }

  /// Keychain et préférences isolés : jamais ceux de l'app hôte des tests.
  private func makeDevice() throws -> Device {
    let configuration = try #require(LocalSupabase.configuration)
    let keychain = KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "tests.it.deletion.\(UUID().uuidString)"))
    let flags = UserDefaultsAccountDeletionFlagStore(defaults: defaults)
    let gateway = SupabaseGateway(configuration: configuration, store: keychain, deletionFlags: flags)
    return Device(gateway: gateway, keychain: keychain, defaults: defaults, flags: flags)
  }

  private func makeEngine(_ device: Device, container: ModelContainer) throws -> SyncEngine {
    SyncEngine(
      gateway: device.gateway, container: container, cursors: UserDefaultsSyncCursors(defaults: device.defaults),
      classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
  }

  /// Créer une liste, cocher en magasin, supprimer : le nouveau compte ne voit rien et ne reçoit rien.
  /// `PARCOURSES_IT_DELETION_OUT` : `integration-test.sh` y lit les identifiants pour vérifier la base.
  @Test func deletionErasesTheAccountAndStartsAnEmptyOne() async throws {
    let device = try makeDevice()
    let old = try await device.gateway.ensureSession()
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    let context = container.mainContext
    try SwiftDataCategoryRepository(context: context).seedIfNeeded()
    let lists = SwiftDataListRepository(context: context)
    let visits = SwiftDataVisitRepository(context: context)
    var engine = try makeEngine(device, container: container)

    let storeId = try #require(
      try await device.gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 1).first
    ).id
    let start = Date.now.addingTimeInterval(-120)
    let list = try lists.createList(name: "IT-68 suppression", at: start)
    let item = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: start)
    let visit = try visits.startVisit(storeId: storeId, listId: list.id, listWasSorted: false, at: start)
    try visits.addCheck(
      visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: start.addingTimeInterval(1))
    try visits.closeVisit(id: visit.id, at: start.addingTimeInterval(2))
    await engine.drain(pull: true)
    #expect(try await device.gateway.fetchLists(updatedAfter: nil).map(\.id) == [list.id])
    #expect(try await device.gateway.visitAccess(id: visit.id) == .closed)
    // Une modification encore en file au moment de la suppression : elle ne doit partir nulle part.
    try lists.renameList(id: list.id, name: "IT-68 jamais envoyée", at: .now)

    let deletion = AccountDeletion(
      gateway: device.gateway, flags: device.flags,
      purge: LocalDataPurge(
        container: container, keychain: device.keychain, defaults: device.defaults,
        urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)),
      isOnline: { true })
    let host = IntegrationDeletionHost(engine: engine)
    deletion.host = host
    await deletion.delete()
    // `host` est une référence faible de la suppression : il doit vivre jusqu'à la fin. La surcharge
    // asynchrone de `withExtendedLifetime` manque au SDK de la CI : on prolonge sa vie après coup.
    withExtendedLifetime(host) {}

    #expect(deletion.status == .deleted)
    #expect(device.flags.load() == nil)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<OutboxEntry>()) == 0)
    let new = try await device.gateway.currentAccountId()
    #expect(new != old)

    // App reconstruite : moteur neuf et passes complètes. Le nouveau compte ne voit et ne reçoit rien.
    engine = try makeEngine(device, container: container)
    await engine.drain(pull: true)
    await engine.drain(pull: true)
    #expect(try await device.gateway.fetchLists(updatedAfter: nil).isEmpty)
    #expect(try await device.gateway.fetchItems(updatedAfter: nil).isEmpty)
    #expect(try await device.gateway.visitAccess(id: visit.id) == .notVisible)
    #expect(try ModelContext(container).fetchCount(FetchDescriptor<OutboxEntry>()) == 0)

    if let path = ProcessInfo.processInfo.environment["PARCOURSES_IT_DELETION_OUT"] {
      try "\(old.uuidString.lowercased()) \(new.uuidString.lowercased()) \(visit.id.uuidString.lowercased())\n"
        .write(toFile: path, atomically: true, encoding: .utf8)
    }
    try device.keychain.removeAll()
  }

  /// Les preuves qui lèvent le doute après une réponse perdue : rafraîchissement refusé, compte introuvable.
  @Test func afterDeletionTheServerProvesIt() async throws {
    let device = try makeDevice()
    let id = try await device.gateway.ensureSession()
    #expect(try await device.gateway.localSessionAccountId() == id)
    #expect(try await device.gateway.confirmAccountDeleted() == false)
    try await device.gateway.deleteAccount()
    // Jeton d'accès encore valable : 403 `user_not_found`, sans rafraîchir ni effacer la session.
    #expect(try await device.gateway.confirmAccountDeleted() == true)
    #expect(try await device.gateway.localSessionAccountId() == id)
    // Rejouée après une réponse perdue, la suppression livre la même preuve, sans créer de compte.
    await #expect(throws: RemoteError.accountGone(code: "user_not_found")) { try await device.gateway.deleteAccount() }
    try await device.gateway.signOutLocally()
    #expect(try await device.gateway.localSessionAccountId() == nil)
    try device.keychain.removeAll()
  }

  /// Drapeau présent : aucun compte n'est créé ; effacé, la connexion anonyme reprend.
  @Test func noAccountIsCreatedWhileTheDeletionIsPending() async throws {
    let device = try makeDevice()
    device.flags.save(AccountDeletionFlag(accountId: nil, phase: .requested))
    await #expect(throws: RemoteError.unauthorized) { try await device.gateway.ensureSession() }
    await #expect(throws: RemoteError.unauthorized) { try await device.gateway.currentAccountId() }
    device.flags.clear()
    _ = try await device.gateway.ensureSession()
    try device.keychain.removeAll()
  }
}

/// Mailpit de la pile locale : les codes de connexion y arrivent (#87).
private nonisolated enum Mailpit {
  static let url: URL = {
    let value = ProcessInfo.processInfo.environment["PARCOURSES_IT_MAILPIT"] ?? "http://127.0.0.1:56324"
    return URL(string: value) ?? URL(filePath: "/")
  }()

  /// Code à 6 chiffres du dernier e-mail reçu par `address` et pas encore lu. Attend au plus 10 s.
  static func code(to address: String, seen: inout Set<String>) async throws -> String {
    var search = URLComponents(url: url.appending(path: "api/v1/search"), resolvingAgainstBaseURL: false)
    search?.queryItems = [URLQueryItem(name: "query", value: "to:\"\(address)\"")]
    let searchURL = try #require(search?.url)
    for _ in 0..<50 {
      let (data, _) = try await URLSession.shared.data(from: searchURL)
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let ids = (object?["messages"] as? [[String: Any]] ?? []).compactMap { $0["ID"] as? String }
      if let id = ids.first(where: { !seen.contains($0) }) {
        seen.insert(id)
        let (body, _) = try await URLSession.shared.data(from: url.appending(path: "api/v1/message/\(id)"))
        let message = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let text = try #require(message["Text"] as? String)
        #expect(!text.contains("http://") && !text.contains("https://"), "le code arrive sans lien")
        return String(try #require(text.firstMatch(of: /\b(\d{6})\b/)).output.1)
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw RemoteError.network
  }
}

/// Comptes e-mail et synchro multi-appareil de bout en bout contre la pile locale (#87, lot 87.3) : liaison par code
/// lu dans Mailpit, adresse déjà prise puis connexion et reprise, deux appareils du même compte, perte de session.
@MainActor
@Suite(.serialized, .enabled(if: LocalSupabase.configuration != nil))
struct AccountsIntegrationTests {
  /// Un appareil : Keychain, préférences, store et moteur isolés.
  private struct Device {
    let remote: SupabaseGateway
    let keychain: KeychainStore
    let defaults: UserDefaults
    let kinds: UserDefaultsAccountKindStore
    let cursors: UserDefaultsSyncCursors
    let container: ModelContainer
    let engine: SyncEngine
    let lists: SwiftDataListRepository

    /// Compte de l'appareil, retenu ici comme par `AppModel` : la liaison s'y adosse (changement de compte).
    let account: AccountSession

    var context: ModelContext { container.mainContext }

    func link() -> AccountLink {
      // Toujours présent : la passerelle existe.
      account.makeLink() ?? AccountLink(gateway: remote, kinds: kinds)
    }

    /// Lecture sur un contexte neuf : le contexte principal reçoit les écritures du moteur plus tard.
    func items() throws -> [ListItem] { try ModelContext(container).fetch(FetchDescriptor<ListItem>()) }
    func listNames() throws -> Set<String> {
      Set(try ModelContext(container).fetch(FetchDescriptor<ShoppingList>()).map(\.name))
    }
  }

  private func makeDevice() async throws -> Device {
    let configuration = try #require(LocalSupabase.configuration)
    let keychain = KeychainStore(service: "app.parcourses.tests.\(UUID().uuidString)")
    let defaults = try #require(UserDefaults(suiteName: "tests.it.accounts.\(UUID().uuidString)"))
    let kinds = UserDefaultsAccountKindStore(defaults: defaults)
    let remote = SupabaseGateway(
      configuration: configuration, store: keychain,
      deletionFlags: UserDefaultsAccountDeletionFlagStore(defaults: defaults), accountKinds: kinds)
    try await remote.ensureSession()
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    try SwiftDataCategoryRepository(context: container.mainContext).seedIfNeeded()
    let cursors = UserDefaultsSyncCursors(defaults: defaults)
    let engine = SyncEngine(
      gateway: remote, container: container, cursors: cursors, classify: try PulledItemClassifier.make(),
      dependencies: SyncEngine.Dependencies(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    let pending = SyncState.pending.rawValue
    let pendingChanges: () -> Int = {
      let descriptor = FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.syncStateRaw == pending })
      return (try? container.mainContext.fetchCount(descriptor)) ?? 0
    }
    let link = AccountLink.Dependencies(
      resendableLists: { id in
        guard cursors.accountId != id else { return 0 }
        return (try? AccountRekey.resendCount(in: container.mainContext, previousAccountId: cursors.accountId)) ?? 0
      },
      synchronize: { await engine.drain(pull: true) },
      sessionDidChange: { Task { await engine.resume() } },
      previousAccountId: { cursors.accountId }, pendingChanges: pendingChanges,
      suspendSync: { await engine.suspend() }, resumeSync: { await engine.resume() })
    let account = AccountSession(
      gateway: remote, kinds: kinds,
      purge: LocalDataPurge(
        container: container, keychain: keychain, defaults: defaults,
        urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)),
      signOutFlags: UserDefaultsAccountSignOutFlagStore(defaults: defaults),
      dependencies: AccountSession.Dependencies(pendingChanges: pendingChanges, link: link))
    return Device(
      remote: remote, keychain: keychain, defaults: defaults, kinds: kinds, cursors: cursors, container: container,
      engine: engine, lists: SwiftDataListRepository(context: container.mainContext), account: account)
  }

  @discardableResult
  private func addItem(_ device: Device, _ label: String, to listId: UUID) throws -> ListItem {
    try device.lists.addItem(
      listId: listId, label: label, normalizedName: label.lowercased(), quantity: nil, productId: nil,
      categoryId: "other", at: .now)
  }

  @Test func twoDevicesOfOneEmailAccountStayInSync() async throws {
    let email = "it-87-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    var seen: Set<String> = []

    // Premier téléphone : compte anonyme, une liste, puis l'adresse liée par le code reçu.
    let a = try await makeDevice()
    let account = try await a.remote.currentAccountId()
    let list = try a.lists.createList(name: "IT-87 A", at: .now)
    let milk = try addItem(a, "Lait", to: list.id)
    let bread = try addItem(a, "Pain", to: list.id)
    await a.engine.drain(pull: true)
    let linkA = a.link()
    #expect(linkA.canLink)
    linkA.email = email
    linkA.displayName = "Léa"
    await linkA.requestCode()
    #expect(linkA.phase == .enterCode && linkA.purpose == .link, "\(String(describing: linkA.error))")
    let codeA = try await Mailpit.code(to: email, seen: &seen)
    await linkA.verify(code: codeA == "000000" ? "111111" : "000000")
    #expect(linkA.error == .invalidCode)
    await linkA.verify(code: codeA)
    #expect(linkA.outcome == .linked)
    #expect(a.kinds.kind == .email)
    // Même compte : aucune donnée ne bouge.
    #expect(try await a.remote.currentAccountId() == account)
    #expect(try await a.remote.accountEmail() == email)
    #expect(try await a.remote.displayName() == "Léa")
    #expect(try a.listNames() == ["IT-87 A"])

    // Second téléphone, anonyme, avec sa propre liste : l'adresse est prise, il se connecte au compte existant.
    let b = try await makeDevice()
    let anonymousB = try await b.remote.currentAccountId()
    let listB = try b.lists.createList(name: "IT-87 B", at: .now)
    try addItem(b, "Café", to: listB.id)
    _ = try b.lists.createList(name: "Courses", at: .now)
    await b.engine.drain(pull: true)
    let linkB = b.link()
    linkB.email = email
    await linkB.requestCode()
    #expect(linkB.purpose == .signIn, "\(String(describing: linkB.error))")
    let codeB = try await Mailpit.code(to: email, seen: &seen)
    await linkB.verify(code: codeB)
    // « Bon retour, Léa ! » : la liste vide jamais modifiée n'est pas ajoutée (vecteur 008).
    #expect(linkB.outcome == .signedIn(displayName: "Léa", addedLists: 1))
    #expect(try await b.remote.currentAccountId() == account)
    #expect(try b.listNames() == ["IT-87 A", "IT-87 B"])
    await a.engine.drain(pull: true)
    #expect(try a.listNames() == ["IT-87 A", "IT-87 B"])

    // Deux champs du même article, un par appareil : les deux gagnent (envoi par champ).
    try a.lists.setChecked(itemId: milk.id, checkedAt: .now, at: .now)
    let milkB = try #require(try b.context.fetch(FetchDescriptor<ListItem>()).first { $0.id == milk.id })
    milkB.quantity = "2"
    try b.context.enqueueUpsert(of: milkB, at: .now, changedFields: [ListItemFields.quantity])
    try b.context.save()
    await a.engine.drain()
    await b.engine.drain()
    let row = try #require(try await a.remote.fetchItems(listId: list.id).first { $0.id == milk.id })
    #expect(row.checkedAt != nil && row.quantity == "2")
    await a.engine.drain(pull: true)
    await b.engine.drain(pull: true)
    for device in [a, b] {
      let local = try #require(try device.items().first { $0.id == milk.id })
      #expect(local.checkedAt != nil && local.quantity == "2")
    }

    // Insertion arrivée au serveur, réponse perdue : l'article n'est pas accusé, puis il est coché. La coche arrive.
    let eggs = try addItem(a, "Œufs", to: list.id)
    let eggsRow = ListItemUpsert(
      id: eggs.id, listId: list.id, productId: nil, label: "Œufs", quantity: nil, checkedAt: nil)
    #expect(try await a.remote.insertItem(eggsRow))
    try a.lists.setChecked(itemId: eggs.id, checkedAt: .now, at: .now)
    await a.engine.drain()
    #expect(try ModelContext(a.container).fetch(FetchDescriptor<OutboxEntry>()).isEmpty)
    await b.engine.drain(pull: true)
    #expect(try b.items().first { $0.id == eggs.id }?.checkedAt != nil)

    // Suppression sur un appareil : la pierre tombale la propage à l'autre.
    try a.lists.deleteItem(id: bread.id)
    await a.engine.drain()
    await b.engine.drain(pull: true)
    #expect(try !b.items().contains { $0.id == bread.id })
    #expect(try b.items().contains { $0.id == milk.id })

    // Perte de session d'un compte e-mail (Keychain vidé) : aucun compte anonyme, la synchro attend (vecteur 009).
    try a.keychain.removeAll()
    await #expect(throws: RemoteError.unauthorized) { try await a.remote.ensureSession() }
    await a.engine.drain(pull: true)
    #expect(await a.engine.isWaitingForSession)
    // Reconnexion avec la même adresse : même compte, rien à réidentifier.
    let relink = a.link()
    #expect(!relink.canLink)
    relink.email = email
    // `max_frequency` (1 s en local) : un second code pour le même compte, trop tôt, serait refusé en 429.
    try await Task.sleep(for: .seconds(2))
    await relink.requestCode()
    #expect(relink.phase == .enterCode, "\(String(describing: relink.error))")
    await relink.verify(code: try await Mailpit.code(to: email, seen: &seen))
    #expect(relink.outcome == .signedIn(displayName: "Léa", addedLists: 0))
    #expect(try await a.remote.currentAccountId() == account)
    #expect(try ModelContext(a.container).fetch(FetchDescriptor<ShoppingList>()).contains { $0.id == list.id })

    if let path = ProcessInfo.processInfo.environment["PARCOURSES_IT_ACCOUNTS_OUT"] {
      try "\(anonymousB.uuidString.lowercased()) \(account.uuidString.lowercased())\n"
        .write(toFile: path, atomically: true, encoding: .utf8)
    }
    try await a.remote.deleteAccount()
    try a.keychain.removeAll()
    try b.keychain.removeAll()
  }

  /// Compte e-mail A sans session, connexion à un autre compte e-mail B : l'appareil est purgé, B ne reçoit rien de A.
  @Test func signingInToAnotherEmailAccountLeavesThePreviousListsBehind() async throws {
    let first = "it-87-a-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    let second = "it-87-b-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    var seen: Set<String> = []
    // Le compte B existe, avec sa liste, créé sur un autre téléphone.
    let other = try await makeDevice()
    _ = try other.lists.createList(name: "IT-87 de B", at: .now)
    await other.engine.drain(pull: true)
    let linkB = other.link()
    linkB.email = second
    await linkB.requestCode()
    await linkB.verify(code: try await Mailpit.code(to: second, seen: &seen))
    let accountB = try await other.remote.currentAccountId()

    // Le téléphone de A : liste envoyée, une modification encore en file, puis la session disparaît.
    let a = try await makeDevice()
    let list = try a.lists.createList(name: "IT-87 de A", at: .now)
    try addItem(a, "Lait", to: list.id)
    await a.engine.drain(pull: true)
    let linkA = a.link()
    linkA.email = first
    await linkA.requestCode()
    await linkA.verify(code: try await Mailpit.code(to: first, seen: &seen))
    try a.lists.renameList(id: list.id, name: "IT-87 de A, renommée", at: .now)
    try a.keychain.removeAll()
    await a.engine.drain(pull: true)
    #expect(await a.engine.isWaitingForSession)

    let switching = a.link()
    #expect(!switching.canLink)
    // L'écran prévient : la modification en file sera perdue.
    #expect(switching.losesPendingChangesOnSwitch)
    switching.email = second
    // `max_frequency` (1 s en local) : B a reçu un code juste avant.
    try await Task.sleep(for: .seconds(2))
    await switching.requestCode()
    #expect(switching.phase == .enterCode, "\(String(describing: switching.error))")
    await switching.verify(code: try await Mailpit.code(to: second, seen: &seen))
    #expect(switching.outcome == .signedIn(displayName: nil, addedLists: 0))
    #expect(try await a.remote.currentAccountId() == accountB)
    #expect(try a.listNames() == ["IT-87 de B"])
    #expect(try await other.remote.fetchLists(updatedAfter: nil).map(\.name) == ["IT-87 de B"])
    #expect(try ModelContext(a.container).fetch(FetchDescriptor<OutboxEntry>()).isEmpty)

    try await other.remote.deleteAccount()
    try a.keychain.removeAll()
    try other.keychain.removeAll()
  }

  /// Déconnexion : session oubliée, appareil purgé, compte anonyme vide ; les listes restent dans le compte.
  @Test func signingOutLeavesTheListsInTheAccount() async throws {
    let email = "it-87-out-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    var seen: Set<String> = []
    let a = try await makeDevice()
    let list = try a.lists.createList(name: "IT-87 déconnexion", at: .now)
    try addItem(a, "Lait", to: list.id)
    await a.engine.drain(pull: true)
    let link = a.link()
    link.email = email
    await link.requestCode()
    await link.verify(code: try await Mailpit.code(to: email, seen: &seen))
    let account = try await a.remote.currentAccountId()

    let session = AccountSession(
      gateway: a.remote, kinds: a.kinds,
      purge: LocalDataPurge(
        container: a.container, keychain: a.keychain, defaults: a.defaults,
        urlCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)))
    await session.refresh()
    #expect(session.kind == .email && session.email == email)
    await session.signOut()
    #expect(try ModelContext(a.container).fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    let fresh = try await a.remote.currentAccountId()
    #expect(fresh != account)
    #expect(try await a.remote.accountEmail() == nil)
    #expect(try await a.remote.fetchLists(updatedAfter: nil).isEmpty)

    // Reconnexion depuis le nouveau compte anonyme : la liste revient.
    let back = try await makeDevice()
    let again = back.link()
    again.email = email
    try await Task.sleep(for: .seconds(2))
    await again.requestCode()
    #expect(again.purpose == .signIn, "\(String(describing: again.error))")
    await again.verify(code: try await Mailpit.code(to: email, seen: &seen))
    #expect(try await back.remote.currentAccountId() == account)
    #expect(try back.listNames() == ["IT-87 déconnexion"])
    try await back.remote.deleteAccount()
    try a.keychain.removeAll()
    try back.keychain.removeAll()
  }
}
