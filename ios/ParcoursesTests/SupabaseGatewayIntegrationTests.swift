import Foundation
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
  private func makeGateway(service: String = UUID().uuidString) throws -> SupabaseGateway {
    let configuration = try #require(LocalSupabase.configuration)
    return SupabaseGateway(
      configuration: configuration, store: KeychainStore(service: "app.parcourses.tests.\(service)"))
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
    let gateway = try makeGateway()
    async let first = gateway.ensureSession()
    async let second = gateway.ensureSession()
    let (a, b) = try await (first, second)
    #expect(a == b)
  }

  @Test func listsAndItemsAreIdempotentAndPrivate() async throws {
    let gateway = try makeGateway()
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

    let stranger = try makeGateway()
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
    let gateway = try makeGateway()
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

  @Test func aChangedAccountIsReportedUntilAccepted() async throws {
    let service = UUID().uuidString
    let store = KeychainStore(service: "app.parcourses.tests.\(service)")
    defer { try? store.removeAll() }
    let gateway = try makeGateway(service: service)
    let id = try await gateway.ensureSession()
    try store.set(Data(UUID().uuidString.utf8), forKey: SupabaseGateway.lastAccountKey)

    await #expect(throws: RemoteError.accountChanged) { try await gateway.ensureSession() }
    await #expect(throws: RemoteError.accountChanged) {
      try await gateway.saveList(ListUpsert(id: UUID(), name: "Perdue"))
    }
    try await gateway.acceptCurrentAccount()
    #expect(try await gateway.ensureSession() == id)
  }

  @Test func anUnknownCategorySlugIsAnError() async throws {
    let gateway = try makeGateway()
    let storeId = try await anyStoreId(gateway)
    let visit = VisitInsert(id: UUID(), storeId: storeId, listId: nil, listWasSorted: false, startedAt: .now)
    try await gateway.createVisit(visit)
    let check = CheckUpload(id: UUID(), visitId: visit.id, target: .category(slug: "inconnue"), checkedAt: .now)
    await #expect(throws: RemoteError.unknownCategory("inconnue")) { try await gateway.insertChecks([check]) }
  }

  @Test func nearbyStoresReturnsSortedDistances() async throws {
    let gateway = try makeGateway()
    let stores = try await gateway.nearbyStores(lat: 43.646, lng: 0.586, radiusM: 20000, maxResults: 5)
    #expect(!stores.isEmpty)
    #expect(stores.map(\.distanceM) == stores.map(\.distanceM).sorted())
    await #expect(throws: RemoteError.rejected(code: "22023")) {
      _ = try await gateway.nearbyStores(lat: 200, lng: 0, radiusM: 1000, maxResults: 1)
    }
  }

  @Test func storeSearchFindsByNameAndTreatsInputAsText() async throws {
    let gateway = try makeGateway()
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
    let gateway = try makeGateway()
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
