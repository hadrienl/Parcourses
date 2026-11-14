import Domain
import Foundation
import SortEngine
import SwiftData
import Testing

@testable import Parcourses

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let productA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
private let productB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
private let productC = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!

/// Instantané où l'ordre du trajet est C → A → B, à l'inverse de l'ordre alphabétique.
private func snapshotJSON(version: Int64 = 7, confidenceQ: Int64 = 720, format: Int = 1) -> Data {
  let a = productA.uuidString.lowercased()
  let b = productB.uuidString.lowercased()
  let c = productC.uuidString.lowercased()
  let json = """
    {"format_version": \(format), "snapshot_version": \(version), "params_version": 1, "store_id": "x",
     "params": {"CONF_THRESHOLD_Q": 500, "COST_SCALE": 1000, "UNKNOWN_BASE": 3000, "CAT_STEP": 200,
                "TWO_OPT_MAX_PASSES": 20, "REORDER_MIN_GAIN_PCT": 10},
     "confidence_q": \(confidenceQ),
     "entries": [{"product_id": "\(c)", "weight_q": 9000}],
     "edges": [{"a": "\(a)", "b": "\(c)", "weight_q": 9000}, {"a": "\(a)", "b": "\(b)", "weight_q": 9000}]}
    """
  return Data(json.utf8)
}

/// Passerelle dont seul l'instantané répond ; tout le reste échoue comme sans session.
private actor SnapshotGateway: RemoteGateway {
  var response: Result<GraphSnapshotResponse, RemoteError>
  private(set) var knownVersions: [Int64?] = []
  private var gate: CheckedContinuation<Void, Never>?
  private var isGated: Bool

  init(_ response: Result<GraphSnapshotResponse, RemoteError> = .success(.none), gated: Bool = false) {
    self.response = response
    isGated = gated
  }

  func openGate() {
    isGated = false
    gate?.resume()
    gate = nil
  }

  var organicAisle: Bool?
  func setOrganicAisle(_ value: Bool?) { organicAisle = value }
  func storeOrganicAisle(id: UUID) async throws -> Bool? { organicAisle }

  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse {
    knownVersions.append(knownVersion)
    if isGated { await withCheckedContinuation { gate = $0 } }
    return try response.get()
  }

  func ensureSession(captchaToken: String?) async throws -> UUID { throw RemoteError.unauthorized }
  func currentAccountId() async throws -> UUID { throw RemoteError.unauthorized }
  func verifySession() async throws { throw RemoteError.unauthorized }
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow] {
    throw RemoteError.unauthorized
  }
  func sessionAccountId() async throws -> UUID { throw RemoteError.unauthorized }
  func acknowledgeAccount(_ id: UUID) async throws { throw RemoteError.unauthorized }
  func deleteAccount() async throws { throw RemoteError.unauthorized }
  func signOutLocally() async throws {}
  func localSessionAccountId() async throws -> UUID? { nil }
  func confirmAccountDeleted() async throws -> Bool { throw RemoteError.unauthorized }
  func serverDate() async throws -> Date? { throw RemoteError.unauthorized }
  func saveList(_ list: ListUpsert) async throws { throw RemoteError.unauthorized }
  func deleteList(id: UUID) async throws { throw RemoteError.unauthorized }
  func saveItem(_ item: ListItemUpsert) async throws { throw RemoteError.unauthorized }
  func deleteItem(id: UUID) async throws { throw RemoteError.unauthorized }
  func createVisit(_ visit: VisitInsert) async throws { throw RemoteError.unauthorized }
  func insertChecks(_ checks: [CheckUpload]) async throws { throw RemoteError.unauthorized }
  func closeVisit(id: UUID, endedAt: Date) async throws { throw RemoteError.unauthorized }
  func visitAccess(id: UUID) async throws -> VisitAccess { throw RemoteError.unauthorized }
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] { throw RemoteError.unauthorized }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] { throw RemoteError.unauthorized }
  func fetchCategories() async throws -> [CategoryRow] { throw RemoteError.unauthorized }
  func fetchProducts() async throws -> [RemoteProduct] { throw RemoteError.unauthorized }
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] {
    throw RemoteError.unauthorized
  }
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] { throw RemoteError.unauthorized }
}

@MainActor
private final class Harness {
  let container: ModelContainer
  let context: ModelContext
  let lists: SwiftDataListRepository
  let visits: SwiftDataVisitRepository
  let stores: SwiftDataStoreRepository
  let graphs: SwiftDataGraphRepository
  let categories: SwiftDataCategoryRepository
  let analyzer: EntryAnalyzer
  let listId: UUID
  let storeId = UUID()
  var date = t0

  init(organicAisle: Bool = false) throws {
    container = try PersistenceStack.makeContainer(storage: .inMemory)
    context = container.mainContext
    lists = SwiftDataListRepository(context: context)
    visits = SwiftDataVisitRepository(context: context)
    stores = SwiftDataStoreRepository(context: context)
    graphs = SwiftDataGraphRepository(context: context)
    categories = SwiftDataCategoryRepository(context: context)
    try categories.seedIfNeeded()
    analyzer = try EntryAnalyzer()
    listId = try lists.createList(name: "Semaine", at: t0).id
    try stores.upsertStore(
      id: storeId, name: "Leclerc Auch", chain: nil, address: nil, lastDistanceM: nil, organicAisle: organicAisle)
  }

  @discardableResult
  func add(_ label: String, product: UUID? = nil) throws -> UUID {
    let entry = analyzer.analyze(label)
    return try lists.addItem(
      listId: listId, label: entry.label, normalizedName: entry.normalizedName, quantity: entry.quantity,
      productId: product, categoryId: entry.categoryId, at: t0
    ).id
  }

  func session(
    withStore: Bool = true, gateway: (any RemoteGateway)? = nil, preloadTimeout: Duration = .seconds(3),
    settleDelay: Duration = .milliseconds(1), activity: (any ShoppingActivityControlling)? = nil
  ) -> ShoppingSession {
    ShoppingSession(
      listId: listId, storeId: withStore ? storeId : nil, lists: lists, visits: visits, stores: stores,
      categories: categories, analyzer: analyzer,
      cache: GraphSnapshotCache(graphs: graphs, gateway: gateway, now: { [self] in date }),
      // Capture forte : un tri encore en attente ne doit pas survivre au conteneur (fetch fatal après sa libération).
      now: { [self] in date }, settleDelay: settleDelay, highlightDelay: .milliseconds(1),
      preloadTimeout: preloadTimeout, activity: activity)
  }

  func outbox(_ kind: OutboxKind) throws -> [OutboxEntry] {
    try context.fetch(FetchDescriptor<OutboxEntry>()).filter { $0.kind == kind }
  }

  func saveSnapshot(_ data: Data = snapshotJSON()) throws {
    try graphs.saveSnapshot(
      storeId: storeId, snapshotVersion: 7, paramsVersion: 1, confidenceQ: 720, payload: data, at: t0)
  }
}

private func row(_ session: ShoppingSession, _ label: String) throws -> ShoppingRow {
  try #require(session.toBuy.first { $0.label == label })
}

@Suite(.serialized) struct ShoppingSessionTests {
  // MARK: - Visite et coches

  @Test func aVisitOnlyLeavesTheDeviceWithItsFirstCheck() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()

    #expect(session.visitId != nil)
    #expect(try harness.outbox(.createVisit).isEmpty)

    session.toggle(try row(session, "lait"))
    #expect(try harness.outbox(.createVisit).count == 1)
    #expect(try harness.outbox(.insertChecks).count == 1)
  }

  @Test func checksWorkWithoutSessionOrNetwork() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session(gateway: SnapshotGateway(.failure(.unauthorized)))
    await session.start()

    #expect(session.errorMessage == nil)
    #expect(session.knowledge == .unknown)
    session.toggle(try row(session, "lait"))

    #expect(session.errorMessage == nil)
    #expect(try harness.visits.checks(visitId: try #require(session.visitId)).count == 1)
    #expect(try harness.lists.items(listId: harness.listId).first?.checkedAt == t0)
  }

  @Test func withoutStoreThereIsNoVisitAtAll() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session(withStore: false)
    await session.start()

    #expect(session.visitId == nil)
    #expect(session.knowledge == .noStore)
    session.toggle(try row(session, "lait"))
    session.finish(keepRemaining: true)

    #expect(try harness.outbox(.createVisit).isEmpty)
    #expect(try harness.outbox(.insertChecks).isEmpty)
    #expect(try harness.visits.openVisit() == nil)
    #expect(session.summary?.checkedCount == 1)
  }

  @Test func aCheckedRowStaysInPlaceThenJoinsTheBasket() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    let before = session.toBuy.map(\.label)

    session.toggle(try row(session, "lait"))
    #expect(session.toBuy.map(\.label) == before)
    #expect(try row(session, "lait").isChecked)
    #expect(session.basket.isEmpty)

    await session.waitUntilSettled()
    #expect(session.toBuy.map(\.label) == ["tomates"])
    #expect(session.basket.map(\.label) == ["lait"])
  }

  @Test func nothingMovesWhileScrollingOrTyping() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()

    session.setScrolling(true)
    session.toggle(try row(session, "lait"))
    try await Task.sleep(for: .milliseconds(30))
    #expect(session.toBuy.count == 2)

    session.input = "pom"
    session.setEditing(true)
    session.setScrolling(false)
    try await Task.sleep(for: .milliseconds(30))
    #expect(session.toBuy.count == 2)

    session.setEditing(false)
    await session.waitUntilSettled()
    #expect(session.toBuy.map(\.label) == ["tomates"])
  }

  @Test func anIdleKeyboardDoesNotFreezeTheList() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    session.setEditing(true)
    session.toggle(try row(session, "lait"))
    await session.waitUntilSettled()
    #expect(session.toBuy.map(\.label) == ["tomates"])
  }

  // MARK: - Tri

  @Test func aLearnedStoreSortsAlongTheRouteAndMarksTheVisit() async throws {
    let harness = try Harness()
    try harness.saveSnapshot()
    try harness.add("article a", product: productA)
    try harness.add("article b", product: productB)
    try harness.add("article c", product: productC)
    let session = harness.session()
    await session.start()

    #expect(session.toBuy.map(\.label) == ["article c", "article a", "article b"])
    #expect(session.mode == .learned)
    #expect(session.knowledge == .learned(72))
    #expect(try harness.visits.openVisit()?.listWasSorted == true)
  }

  @Test func aLowConfidenceStoreUsesTheGenericOrder() async throws {
    let harness = try Harness()
    try harness.saveSnapshot(snapshotJSON(confidenceQ: 200))
    try harness.add("article a", product: productA)
    try harness.add("article c", product: productC)
    let session = harness.session()
    await session.start()

    #expect(session.mode == .fallback)
    #expect(session.knowledge == .learning(20))
    #expect(try harness.visits.openVisit()?.listWasSorted == false)
  }

  /// Le gain de l'ordre appris ne suffit pas à déplacer ce qui est déjà affiché quand il reste sous 10 %.
  @Test func theNextSortKeepsTheDisplayedOrderWhenTheGainIsSmall() async throws {
    let harness = try Harness()
    try harness.saveSnapshot()
    try harness.add("article a", product: productA)
    try harness.add("article b", product: productB)
    try harness.add("article c", product: productC)
    let session = harness.session()
    await session.start()

    session.toggle(try row(session, "article c"))
    await session.waitUntilSettled()
    #expect(session.toBuy.map(\.label) == ["article a", "article b"])
  }

  @Test func aSnapshotArrivingDuringTheVisitWaitsForTheNextCheck() async throws {
    let harness = try Harness()
    try harness.add("article a", product: productA)
    try harness.add("article b", product: productB)
    try harness.add("article c", product: productC)
    let gateway = SnapshotGateway(.success(.payload(snapshotJSON())), gated: true)
    let session = harness.session(gateway: gateway, preloadTimeout: .milliseconds(1))
    await session.start()
    #expect(session.knowledge == .unknown)
    #expect(try harness.visits.openVisit()?.listWasSorted == false)

    await gateway.openGate()
    try await Task.sleep(for: .milliseconds(50))
    #expect(session.knowledge == .unknown)
    #expect(try harness.graphs.snapshot(storeId: harness.storeId)?.snapshotVersion == 7)

    session.toggle(try row(session, "article a"))
    #expect(session.knowledge == .learned(72))
    await session.waitUntilSettled()
    #expect(session.mode == .learned)
  }

  @Test func aSnapshotReceivedBeforeTheTimeoutIsUsedFromTheStart() async throws {
    let harness = try Harness()
    try harness.add("article a", product: productA)
    let gateway = SnapshotGateway(.success(.payload(snapshotJSON())))
    let session = harness.session(gateway: gateway)
    await session.start()
    #expect(session.mode == .learned)
    #expect(try harness.visits.openVisit()?.listWasSorted == true)
  }

  // MARK: - Rayon bio

  @Test(arguments: [true, false])
  func anOrganicItemGoesToTheOrganicAisleOnlyWhereThereIsOne(hasAisle: Bool) async throws {
    let harness = try Harness(organicAisle: hasAisle)
    try harness.add("lait bio")
    try harness.add("yaourt")
    let session = harness.session()
    await session.start()
    // Rayon bio : rang 85, après la crèmerie. Sans rayon : même catégorie, tri par nom.
    #expect(session.toBuy.map(\.label) == (hasAisle ? ["yaourt", "lait bio"] : ["lait bio", "yaourt"]))
  }

  @Test func anOrganicFrozenItemStaysFrozen() async throws {
    let harness = try Harness(organicAisle: true)
    try harness.add("petits pois bio surgelés")
    try harness.add("café")
    let session = harness.session()
    await session.start()
    // Le café (rang 100) passe après le rayon bio (85) et avant les surgelés (150).
    #expect(session.toBuy.map(\.label) == ["café", "petits pois bio surgelés"])
  }

  @Test func theOrganicAisleNeverReachesACheck() async throws {
    let harness = try Harness(organicAisle: true)
    try harness.add("lait bio")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait bio"))
    let visitId = try #require(session.visitId)
    let check = try #require(try harness.visits.checks(visitId: visitId).first)
    #expect(check.categoryId == harness.analyzer.classify(label: "lait bio").categoryId)
    #expect(check.categoryId != organicCategoryId)
    #expect(check.productId == nil)
  }

  @Test func aProductItemIsCheckedByProduct() async throws {
    let harness = try Harness()
    try harness.add("article a", product: productA)
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "article a"))
    let visitId = try #require(session.visitId)
    let check = try #require(try harness.visits.checks(visitId: visitId).first)
    #expect(check.productId == productA)
    #expect(check.categoryId == nil)
  }

  // MARK: - Annulation

  @Test func aCheckIsHeldBackDuringTheUndoWindow() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))

    let store = SyncStore(modelContainer: harness.container)
    // L'article (coché) part aussitôt, ni la visite ni la coche.
    let beforeWindow = try #require(try await store.nextWork(now: t0.addingTimeInterval(4.9)))
    #expect(beforeWindow.kind == .upsertList)
    #expect(try harness.outbox(.createVisit).first?.nextAttemptAt == t0.addingTimeInterval(5))
    #expect(try harness.outbox(.insertChecks).first?.nextAttemptAt == t0.addingTimeInterval(5))
  }

  @Test func undoLeavesNoTraceForTheServer() async throws {
    let harness = try Harness()
    let id = try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    let before = session.toBuy.map(\.id)

    session.toggle(try row(session, "lait"))
    #expect(session.undo?.kind == .check)
    session.performUndo()

    #expect(session.undo == nil)
    #expect(session.toBuy.map(\.id) == before)
    #expect(session.toBuy.allSatisfy { !$0.isChecked })
    #expect(try harness.visits.checks(visitId: try #require(session.visitId)).isEmpty)
    #expect(try harness.outbox(.createVisit).isEmpty)
    #expect(try harness.outbox(.insertChecks).isEmpty)
    #expect(try harness.lists.items(listId: harness.listId).first { $0.id == id }?.checkedAt == nil)
  }

  @Test func undoOfASecondCheckKeepsTheVisitCreation() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    session.toggle(try row(session, "tomates"))
    session.performUndo()

    #expect(try harness.outbox(.createVisit).count == 1)
    #expect(try harness.outbox(.insertChecks).count == 1)
  }

  @Test func checkingAgainAfterUndoRecreatesTheVisit() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    session.performUndo()
    session.toggle(try row(session, "lait"))
    #expect(try harness.outbox(.createVisit).count == 1)
    #expect(try harness.outbox(.insertChecks).count == 1)
  }

  @Test func undoExpires() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = ShoppingSession(
      listId: harness.listId, storeId: nil, lists: harness.lists, visits: harness.visits, stores: harness.stores,
      categories: harness.categories, analyzer: harness.analyzer,
      cache: GraphSnapshotCache(graphs: harness.graphs, gateway: nil), now: { [harness] in harness.date },
      undoDelay: .milliseconds(5))
    await session.start()
    session.toggle(try row(session, "lait"))
    #expect(session.undo != nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(session.undo == nil)
  }

  @Test func tappingACheckedRowAfterSendingKeepsTheServerTrace() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    await session.waitUntilSettled()
    // La file a envoyé la coche.
    for entry in try harness.outbox(.insertChecks) { harness.context.delete(entry) }
    try harness.context.save()

    session.toggle(try #require(session.basket.first))

    #expect(session.basket.isEmpty)
    #expect(session.toBuy.map(\.label) == ["lait"])
    #expect(try harness.visits.checks(visitId: try #require(session.visitId)).count == 1)
  }

  // MARK: - Relecture de la PR #41

  @Test func aSecondStartReusesTheOpenVisit() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let first = harness.session()
    await first.start()
    let second = harness.session()
    await second.start()
    #expect(first.visitId == second.visitId)
    #expect(try harness.context.fetchCount(FetchDescriptor<Visit>()) == 1)
  }

  @Test func startingElsewhereClosesTheOpenVisit() throws {
    let harness = try Harness()
    let open = try harness.visits.startVisit(storeId: UUID(), listId: harness.listId, listWasSorted: false, at: t0)
    let openId = open.id
    try harness.visits.addCheck(visitId: openId, itemId: UUID(), subject: .category("other"), checkedAt: t0)
    let next = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    #expect(next.id != openId)
    #expect(try harness.visits.visit(id: openId)?.endedAt == t0)
    #expect(try harness.visits.openVisit()?.id == next.id)
  }

  @Test func aRecentStoreKeepsTheCachedOrganicAisleAndTheServerWins() async throws {
    let harness = try Harness(organicAisle: true)
    // Choisir un récent (`nil`) n'écrase rien.
    try harness.stores.upsertStore(
      id: harness.storeId, name: "Leclerc Auch", chain: nil, address: nil, lastDistanceM: nil, organicAisle: nil)
    #expect(try harness.stores.store(id: harness.storeId)?.organicAisle == true)

    try harness.stores.updateOrganicAisle(id: harness.storeId, organicAisle: false)
    try harness.add("lait bio")
    try harness.add("yaourt")
    let gateway = SnapshotGateway()
    await gateway.setOrganicAisle(true)
    let session = harness.session(gateway: gateway)
    await session.start()
    #expect(try harness.stores.store(id: harness.storeId)?.organicAisle == true)
    #expect(session.toBuy.map(\.label) == ["yaourt", "lait bio"])
  }

  @Test func aSortAlreadyRunningCannotMoveTheRowJustChecked() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    try harness.add("yaourt")
    let session = harness.session(settleDelay: .milliseconds(200))
    await session.start()
    session.toggle(try row(session, "lait"))
    try await Task.sleep(for: .milliseconds(10))
    let order = session.toBuy.map(\.label)
    session.toggle(try row(session, "tomates"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(session.toBuy.map(\.label) == order)
    #expect(session.basket.isEmpty)
  }

  @Test func undoingOneCheckKeepsTheOtherCheckPendingSort() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session(settleDelay: .milliseconds(30))
    await session.start()
    session.toggle(try row(session, "lait"))
    session.toggle(try row(session, "tomates"))
    session.performUndo()
    #expect(session.toBuy.count == 2)
    #expect(try row(session, "lait").isChecked)
    await session.waitUntilSettled()
    #expect(session.basket.map(\.label) == ["lait"])
    #expect(session.toBuy.map(\.label) == ["tomates"])
  }

  @Test func otherActionsLeaveAJustCheckedRowInPlace() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    try harness.add("yaourt")
    let session = harness.session(settleDelay: .seconds(60))
    await session.start()
    session.toggle(try row(session, "lait"))
    session.markNotFound(try row(session, "yaourt"))
    #expect(try row(session, "lait").isChecked)
    #expect(session.basket.isEmpty)
    session.restore(try #require(session.notFound.first))
    #expect(try row(session, "lait").isChecked)
    session.toggle(try row(session, "tomates"))
    session.toggle(try row(session, "tomates"))
    #expect(try row(session, "lait").isChecked)
    #expect(session.basket.isEmpty)
    // Une ligne en attente n'est pas un article restant.
    session.finish(keepRemaining: false)
    #expect(try harness.lists.items(listId: harness.listId).contains { $0.label == "lait" })
  }

  @Test func aRefusedCheckLeavesListAndRowsUntouched() async throws {
    let harness = try Harness()
    let id = try harness.add("lait")
    let session = harness.session()
    await session.start()
    // Visite close derrière le dos de la session : la coche est refusée.
    try harness.visits.addCheck(
      visitId: try #require(session.visitId), itemId: UUID(), subject: .category("other"), checkedAt: t0)
    try harness.visits.closeVisit(id: try #require(session.visitId), at: t0)
    let upserts = try harness.outbox(.upsertItem).count

    session.toggle(try row(session, "lait"))

    #expect(session.errorMessage != nil)
    #expect(try harness.lists.items(listId: harness.listId).first { $0.id == id }?.checkedAt == nil)
    #expect(try !row(session, "lait").isChecked)
    #expect(session.undo == nil)
    #expect(try harness.outbox(.upsertItem).count == upserts)
  }

  /// Point 8 : l'entrée partie pendant l'envoi n'est ni recréée ni bloquante.
  @Test func anEntryRemovedWhileBeingSentIsIgnored() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    let store = SyncStore(modelContainer: harness.container)
    let entry = try #require(try harness.outbox(.insertChecks).first)
    let work = OutboxWork(
      entryIds: [entry.id], kind: .insertChecks, entityId: entry.entityId, payloads: [entry.payload], attempts: 0)
    session.performUndo()
    try await store.complete(work)
    try await store.postpone(work, attempts: 1, until: t0, reason: "test")
    #expect(try harness.outbox(.insertChecks).isEmpty)
  }

  // MARK: - Introuvable

  @Test func notFoundLeavesTheRouteAndCanBeUndone() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()

    session.markNotFound(try row(session, "lait"))
    #expect(session.notFound.map(\.label) == ["lait"])
    #expect(session.toBuy.map(\.label) == ["tomates"])
    #expect(try harness.outbox(.insertChecks).isEmpty)

    session.performUndo()
    #expect(session.notFound.isEmpty)
    #expect(session.toBuy.count == 2)
  }

  // MARK: - Ajout en route

  @Test func addingOnTheWayInsertsWithoutMovingTheOthers() async throws {
    let harness = try Harness()
    try harness.add("article a", product: productA)
    try harness.add("article b", product: productB)
    let session = harness.session()
    await session.start()
    let before = session.toBuy.map(\.label)

    session.input = "2 tomates"
    await session.submit()

    #expect(session.input.isEmpty)
    #expect(session.toBuy.filter { $0.label != "tomates" }.map(\.label) == before)
    #expect(try row(session, "tomates").quantity == "2")
    #expect(session.highlightedItemId != nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(session.highlightedItemId == nil)
  }

  // MARK: - Fin

  @Test func finishingCanKeepTheRemainingItems() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    try harness.add("xyzzy")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    await session.waitUntilSettled()
    session.markNotFound(try row(session, "xyzzy"))
    #expect(session.remainingCount == 2)

    harness.date = t0.addingTimeInterval(18 * 60)
    session.finish(keepRemaining: true)

    let items = try harness.lists.items(listId: harness.listId)
    #expect(items.count == 3)
    #expect(items.allSatisfy { $0.notFoundAt == nil })
    #expect(try harness.outbox(.closeVisit).count == 1)
    #expect(
      session.summary
        == ShoppingSummary(
          checkedCount: 1, minutes: 18, storeName: "Leclerc Auch", knowledge: .unknown))
  }

  @Test func finishingCanDropTheRemainingItems() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))
    await session.waitUntilSettled()
    session.finish(keepRemaining: false)
    #expect(try harness.lists.items(listId: harness.listId).map(\.label) == ["lait"])
  }

  @Test func aVisitWithoutCheckIsNeverSent() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.finish(keepRemaining: true)
    #expect(try harness.visits.openVisit() == nil)
    #expect(try harness.outbox(.closeVisit).isEmpty)
    #expect(session.summary?.checkedCount == 0)
  }

  @Test func aVisitExpiresAfter45MinutesAtTheLastCheck() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    harness.date = t0.addingTimeInterval(600)
    session.toggle(try row(session, "lait"))
    let visitId = try #require(session.visitId)

    harness.date = t0.addingTimeInterval(600 + ShoppingSession.expiry - 1)
    session.foregrounded()
    #expect(!session.expired)

    harness.date = t0.addingTimeInterval(600 + ShoppingSession.expiry)
    session.foregrounded()
    #expect(session.expired)
    #expect(try harness.visits.visit(id: visitId)?.endedAt == t0.addingTimeInterval(600))
    #expect(session.summary == nil)

    session.finish(keepRemaining: true)
    #expect(session.summary?.minutes == 10)
  }

  @Test func resumingReopensTheVisitAndTheBasket() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let first = harness.session()
    await first.start()
    first.toggle(try row(first, "lait"))
    await first.waitUntilSettled()

    let visit = try #require(try harness.visits.openVisit())
    let resumed = harness.session()
    await resumed.resume(visit: visit)
    #expect(resumed.visitId == visit.id)
    #expect(resumed.basket.map(\.label) == ["lait"])
    #expect(resumed.toBuy.map(\.label) == ["tomates"])
  }

  @Test func itemsCheckedBeforeTheVisitAreNotCounted() async throws {
    let harness = try Harness()
    let id = try harness.add("lait")
    try harness.lists.setChecked(itemId: id, checkedAt: t0.addingTimeInterval(-3600), at: t0)
    let session = harness.session()
    await session.start()
    session.finish(keepRemaining: true)
    #expect(session.summary?.checkedCount == 0)
  }
}

@Suite(.serialized) struct GraphSnapshotCacheTests {
  @Test func aNewVersionIsStoredAndTheKnownVersionSentNextTime() async throws {
    let harness = try Harness()
    let gateway = SnapshotGateway(.success(.payload(snapshotJSON())))
    let cache = GraphSnapshotCache(graphs: harness.graphs, gateway: gateway)

    let loaded = try await cache.refresh(storeId: harness.storeId)
    #expect(loaded?.version == 7)
    #expect(cache.cached(storeId: harness.storeId)?.snapshot.confidenceQ == 720)

    await gateway.setResponse(.success(.unchanged))
    #expect(try await cache.refresh(storeId: harness.storeId) == nil)
    #expect(await gateway.knownVersions == [nil, 7])
    #expect(cache.cached(storeId: harness.storeId)?.version == 7)
  }

  @Test func noSnapshotOnTheServerKeepsTheCache() async throws {
    let harness = try Harness()
    try harness.saveSnapshot()
    let cache = GraphSnapshotCache(graphs: harness.graphs, gateway: SnapshotGateway(.success(.none)))
    #expect(try await cache.refresh(storeId: harness.storeId) == nil)
    #expect(cache.cached(storeId: harness.storeId)?.version == 7)
  }

  @Test func anUnknownFormatIsIgnoredAndAskedAgainInFull() async throws {
    let harness = try Harness()
    let gateway = SnapshotGateway(.success(.payload(snapshotJSON(format: 2))))
    let cache = GraphSnapshotCache(graphs: harness.graphs, gateway: gateway)
    #expect(try await cache.refresh(storeId: harness.storeId) == nil)
    #expect(cache.cached(storeId: harness.storeId) == nil)

    try harness.saveSnapshot(snapshotJSON(format: 2))
    #expect(cache.cached(storeId: harness.storeId) == nil)
    await gateway.setResponse(.success(.none))
    _ = try await cache.refresh(storeId: harness.storeId)
    #expect(await gateway.knownVersions == [nil, nil])
  }

  @Test func theResponseIsParsed() {
    #expect(GraphSnapshotResponse.parse(Data("null".utf8)) == .unchanged)
    #expect(GraphSnapshotResponse.parse(Data("{\"none\": true}".utf8)) == .none)
    let payload = snapshotJSON()
    #expect(GraphSnapshotResponse.parse(payload) == .payload(payload))
  }
}

extension SnapshotGateway {
  fileprivate func setResponse(_ value: Result<GraphSnapshotResponse, RemoteError>) { response = value }
}

@Suite struct OrganicAisleCacheTests {
  @Test func rowsWithoutTheColumnStillDecode() throws {
    let id = UUID().uuidString
    let old = Data("{\"id\":\"\(id)\",\"name\":\"M\",\"chain\":null,\"address\":null,\"distance_m\":3}".utf8)
    #expect(try JSONDecoder().decode(NearbyStoreRow.self, from: old).organicAisle == nil)
    let new = Data("{\"id\":\"\(id)\",\"name\":\"M\",\"organic_aisle\":true}".utf8)
    #expect(try JSONDecoder().decode(StoreSearchRow.self, from: new).organicAisle == true)
  }

  /// Un store écrit par la version précédente de l'app s'ouvre, sans rien perdre.
  @Test func aV1StoreMigratesToV2() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString).store")
    defer {
      for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix)) }
    }
    let id = UUID()
    do {
      let schema = Schema(versionedSchema: SchemaV1.self)
      let container = try ModelContainer(
        for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
      let context = ModelContext(container)
      context.insert(SchemaV1.Store(id: id, name: "Leclerc"))
      context.insert(SchemaV1.ShoppingList(name: "Semaine"))
      try context.save()
    }
    let container = try PersistenceStack.makeContainer(storage: .file(url))
    let context = ModelContext(container)
    let store = try #require(try context.fetch(FetchDescriptor<Store>()).first)
    #expect(store.id == id)
    #expect(store.name == "Leclerc")
    #expect(store.organicAisle == false)
    #expect(try context.fetchCount(FetchDescriptor<ShoppingList>()) == 1)
  }
}

/// Une file écrite par la version précédente garde ses entrées, sans panne en cours.
@Suite struct OutboxMigrationTests {
  @Test func aV2StoreMigratesToV3WithItsQueue() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "migration-\(UUID().uuidString).store")
    defer {
      for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix)) }
    }
    let entityId = UUID()
    do {
      let schema = Schema(versionedSchema: SchemaV2.self)
      let container = try ModelContainer(
        for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
      let context = ModelContext(container)
      context.insert(SchemaV1.OutboxEntry(sequence: 7, kind: .upsertList, entityId: entityId, payload: Data([1])))
      try context.save()
    }
    let context = ModelContext(try PersistenceStack.makeContainer(storage: .file(url)))
    let entry = try #require(try context.fetch(FetchDescriptor<OutboxEntry>()).first)
    #expect(entry.entityId == entityId && entry.sequence == 7 && entry.kind == .upsertList)
    #expect(entry.serverFailingSince == nil)
  }
}

/// Perte de session pendant les courses : la visite continue sous ses nouveaux identifiants.
@Suite(.serialized) struct ShoppingSessionRekeyTests {
  @Test func aVisitInProgressSurvivesTheRekey() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("pommes")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    let oldVisit = try #require(session.visitId)
    session.toggle(try row(session, "lait"))
    let oldUndo = try #require(session.undo)

    let remap = try AccountRekey.run(in: harness.context, now: t0)
    NotificationCenter.default.post(
      name: .syncDidRekeyData, object: nil, userInfo: [IdentifierRemap.userInfoKey: remap])

    let visitId = try #require(session.visitId)
    #expect(visitId != oldVisit)
    #expect(try harness.visits.openVisit()?.id == visitId)
    #expect(session.undo?.itemId == remap[oldUndo.itemId])
    #expect(session.undo?.checkId == oldUndo.checkId.map { remap[$0] })

    // Annuler, cocher, ajouter puis finir fonctionnent sur les nouveaux identifiants.
    session.performUndo()
    #expect(session.errorMessage == nil)
    #expect(try harness.visits.checks(visitId: visitId).isEmpty)
    session.toggle(try row(session, "pommes"))
    #expect(session.errorMessage == nil)
    #expect(try harness.visits.checks(visitId: visitId).count == 1)
    #expect(try harness.outbox(.createVisit).count == 1)
    session.finish(keepRemaining: true)
    #expect(session.errorMessage == nil)
    #expect(try harness.outbox(.closeVisit).first?.entityId == visitId)
    #expect(try harness.lists.lists().first?.id == remap[harness.listId])
  }
}

/// Premières courses réelles : magasin sans instantané, aucun produit, catégories locales correctes.
@Suite(.serialized) struct ShoppingGroupingTests {
  /// position | libellé | catégorie | coché, tels que relevés sur l'iPhone.
  private static let device: [(label: String, category: String, checked: Bool)] = [
    ("Moutarde", "savory-grocery", true), ("Papier toilette", "hygiene", true),
    ("Lessive rainett 0%", "household", false), ("Lait demi écrémé", "dairy", true),
    ("Whey protein deluxe vanilla flavor", "other", false), ("Cornichons", "savory-grocery", true),
    ("Viande pot au feu", "butcher", true), ("Saucisse de Toulouse", "butcher", true),
    ("Concentré de tomate", "savory-grocery", true),
  ]

  @MainActor
  private func seed(_ harness: Harness, checked: Bool) throws {
    for entry in Self.device {
      let item = try harness.lists.addItem(
        listId: harness.listId, label: entry.label,
        normalizedName: harness.analyzer.analyze(entry.label).normalizedName,
        quantity: nil, productId: nil, categoryId: entry.category, at: t0)
      if checked && entry.checked { try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0) }
    }
  }

  @MainActor @Test func theGenericOrderFollowsTheCategoryRanksOnTheDeviceItems() async throws {
    let harness = try Harness()
    try seed(harness, checked: false)
    let session = harness.session()
    await session.start()

    #expect(session.knowledge == .unknown)
    #expect(session.mode == .fallback)
    let ranks = Dictionary(uniqueKeysWithValues: try harness.categories.categories().map { ($0.id, $0.rank) })
    #expect(ranks["butcher"] == 30 && ranks["dairy"] == 70 && ranks["other"] == 999)
    let shown = session.toBuy.map(\.label)
    #expect(
      shown == [
        "Saucisse de Toulouse", "Viande pot au feu", "Lait demi écrémé", "Concentré de tomate", "Cornichons",
        "Moutarde", "Papier toilette", "Lessive rainett 0%", "Whey protein deluxe vanilla flavor",
      ])
  }

  @MainActor @Test func theRemainingDeviceItemsAreInRankOrderToo() async throws {
    let harness = try Harness()
    try seed(harness, checked: true)
    let session = harness.session()
    await session.start()
    #expect(session.toBuy.map(\.label) == ["Lessive rainett 0%", "Whey protein deluxe vanilla flavor"])
    #expect(session.basket.count == 7)
  }

  @MainActor @Test func unknownOrderIsShownByAisleWithTheCategoryLabels() async throws {
    let harness = try Harness()
    try seed(harness, checked: false)
    let session = harness.session()
    await session.start()

    #expect(session.groupsByAisle)
    let sections = session.sections
    #expect(
      sections.map(\.aisleId) == ["butcher", "dairy", "savory-grocery", "hygiene", "household", "other"])
    let labels = Dictionary(uniqueKeysWithValues: try harness.categories.categories().map { ($0.id, $0.label) })
    #expect(sections.map(\.title) == sections.map { labels[$0.aisleId] ?? "" })
    #expect(sections.allSatisfy { !$0.title.isEmpty && $0.title != $0.aisleId })
    #expect(sections[2].rows.map(\.label) == ["Concentré de tomate", "Cornichons", "Moutarde"])
    #expect(sections[0].accessibilityLabel == "\(sections[0].title), 2 articles")
    #expect(sections.flatMap(\.rows).map(\.label) == session.toBuy.map(\.label))
  }

  @MainActor @Test func aCheckedRowStaysInItsAisleUntilTheNextSort() async throws {
    let harness = try Harness()
    try seed(harness, checked: false)
    let session = harness.session()
    await session.start()

    session.toggle(try row(session, "Cornichons"))
    let tomatoes = try #require(session.sections.first { $0.aisleId == "savory-grocery" })
    #expect(tomatoes.rows.map(\.label) == ["Concentré de tomate", "Cornichons", "Moutarde"])
    #expect(tomatoes.rows[1].isChecked)
    #expect(tomatoes.remainingCount == 2)

    await session.waitUntilSettled()
    #expect(try #require(session.sections.first { $0.aisleId == "savory-grocery" }).rows.count == 2)
    #expect(session.basket.map(\.label) == ["Cornichons"])
  }

  @MainActor @Test func theOrganicAisleHasItsOwnSectionWhenTheStoreHasOne() async throws {
    let harness = try Harness(organicAisle: true)
    try harness.add("tomates bio")
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    let sections = session.sections
    #expect(sections.map(\.aisleId).contains("bio"))
    #expect(sections.first { $0.aisleId == "bio" }?.rows.map(\.label) == ["tomates bio"])
    #expect(sections.first { $0.aisleId == "bio" }?.title == "Bio")
  }

  @MainActor @Test func withoutStoreTheListIsAlsoGroupedByAisle() async throws {
    let harness = try Harness()
    try seed(harness, checked: false)
    let session = harness.session(withStore: false)
    await session.start()
    #expect(session.knowledge == .noStore)
    #expect(session.groupsByAisle)
    #expect(session.sections.count == 6)
  }

  /// Ordre appris : l'ordre du tri est gardé, les rayons se posent le long du trajet (B3, lot 9.11).
  @MainActor @Test func aLearnedOrderKeepsTheRouteWithAislesAlongIt() async throws {
    let harness = try Harness()
    try harness.add("farine", product: productA)
    try harness.add("lait", product: productB)
    try harness.add("pommes", product: productC)
    try harness.saveSnapshot()
    let session = harness.session()
    await session.start()

    #expect(session.knowledge == .learned(72))
    #expect(session.mode == .learned)
    #expect(!session.groupsByAisle)
    #expect(session.toBuy.map(\.label) == ["pommes", "farine", "lait"])
    let sections = session.displayedSections
    #expect(sections == session.routeSections)
    #expect(sections.flatMap(\.rows) == session.toBuy)
    #expect(zip(sections, sections.dropFirst()).allSatisfy { $0.aisleId != $1.aisleId })
    #expect(sections.allSatisfy { !$0.title.isEmpty })
  }

  @MainActor @Test func aLearningOrderIsGroupedByAisle() async throws {
    let harness = try Harness()
    try harness.add("farine", product: productA)
    try harness.add("lait", product: productB)
    try harness.graphs.saveSnapshot(
      storeId: harness.storeId, snapshotVersion: 7, paramsVersion: 1, confidenceQ: 300,
      payload: snapshotJSON(confidenceQ: 300), at: t0)
    let session = harness.session()
    await session.start()

    #expect(session.knowledge == .learning(30))
    #expect(session.groupsByAisle)
    #expect(session.sections.count == 2)
  }
}

// MARK: - Live Activity (9.10)

private typealias ActivityState = ShoppingActivityAttributes.ContentState

/// Enregistre ce que le mode courses demande à la Live Activity.
@MainActor
private final class RecordingActivity: ShoppingActivityControlling {
  enum Call {
    case start(ShoppingActivityAttributes, ActivityState)
    case update(ActivityState)
    case end(ActivityState)
  }

  private(set) var calls: [Call] = []
  private(set) var retryCount = 0
  private(set) var endAllKeeping: [UUID?] = []
  /// Dernière activité transmise à chaque démarrage ou mise à jour.
  private(set) var lastActivities: [Date] = []
  /// Ce que `restore` rend : l'état affiché d'une visite.
  var restored: [UUID: ActivityState] = [:]

  func start(attributes: ShoppingActivityAttributes, state: ActivityState, lastActivity: Date) {
    calls.append(.start(attributes, state))
    lastActivities.append(lastActivity)
  }
  func update(state: ActivityState, lastActivity: Date) {
    calls.append(.update(state))
    lastActivities.append(lastActivity)
  }
  func end(state: ActivityState) { calls.append(.end(state)) }
  func retryIfNeeded() { retryCount += 1 }
  func endAll(except visitId: UUID?) { endAllKeeping.append(visitId) }
  private(set) var rekeys: [UUID: UUID] = [:]
  func rekeyed(from oldVisitId: UUID, to newVisitId: UUID) { rekeys[oldVisitId] = newVisitId }
  func restore(visitId: UUID) async -> ActivityState? { restored[visitId] }
  func waitUntilIdle() async {
    // Rien d'asynchrone à attendre.
  }

  var endCount: Int {
    calls.filter {
      if case .end = $0 { true } else { false }
    }.count
  }

  var states: [ActivityState] {
    calls.map {
      switch $0 {
      case .start(_, let state), .update(let state), .end(let state): state
      }
    }
  }
}

private func rows(_ labels: [String], checked: Set<String> = [], aisle: String = "dairy") -> [ShoppingRow] {
  labels.map { ShoppingRow(id: UUID(), label: $0, quantity: nil, isChecked: checked.contains($0), aisleId: aisle) }
}

@Suite struct ShoppingActivityStateTests {
  @Test func theStateCountsRemainingAndTotalAndNamesTheNextItem() {
    let state = ActivityState.make(
      toBuy: rows(["lait", "beurre", "pain"], checked: ["lait"]), basket: rows(["riz"], checked: ["riz"]),
      categoryLabel: { $0 == "dairy" ? "Crèmerie" : nil })
    #expect(state.remaining == 2)
    #expect(state.total == 4)
    #expect(state.nextItemLabel == "beurre")
    #expect(state.nextCategoryLabel == "Crèmerie")
    #expect(state.nextAisleId == "dairy")
    #expect(!state.isFinished)
    #expect(state.progress == 0.5)
  }

  @Test func aRowJustCheckedNoLongerCountsNorIsNext() {
    let state = ActivityState.make(
      toBuy: rows(["lait", "pain"], checked: ["lait"]), basket: [], categoryLabel: { _ in nil })
    #expect(state.remaining == 1)
    #expect(state.nextItemLabel == "pain")
    #expect(state.nextCategoryLabel == nil)
  }

  @Test func withNothingLeftThereIsNoNextItem() {
    let state = ActivityState.make(
      toBuy: rows(["lait"], checked: ["lait"]), basket: [], categoryLabel: { _ in "x" })
    #expect(state.remaining == 0)
    #expect(state.nextItemLabel == nil)
    #expect(state.nextCategoryLabel == nil)
    #expect(state.progress == 1)
  }

  @Test func anEmptyVisitHasNoProgress() {
    let state = ActivityState.make(toBuy: [], basket: [], categoryLabel: { _ in nil })
    #expect(state.total == 0)
    #expect(state.progress == 0)
  }

  @Test func theStateSurvivesEncoding() throws {
    let state = ActivityState(remaining: 3, total: 5, nextItemLabel: "lait", nextCategoryLabel: "Crèmerie")
    let decoded = try JSONDecoder().decode(ActivityState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
  }
}

@Suite(.serialized) @MainActor struct ShoppingActivityTriggerTests {
  @Test func startingPublishesTheFirstStateOnce() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()

    guard case .start(let attributes, let state)? = activity.calls.first else {
      Issue.record("pas de démarrage")
      return
    }
    #expect(activity.calls.count == 1)
    #expect(attributes.listName == "Semaine")
    #expect(attributes.storeName == "Leclerc Auch")
    #expect(state.remaining == 2)
    #expect(state.total == 2)
    #expect(state.nextItemLabel != nil)
  }

  @Test func checkingUpdatesTheProgressAndTheNextItem() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    let labels = session.toBuy.map(\.label)
    #expect(labels.count == 2)
    #expect(activity.states.last?.nextItemLabel == labels[0])
    let before = activity.calls.count
    session.toggle(try row(session, labels[0]))

    #expect(activity.calls.count == before + 1)
    guard case .update(let state)? = activity.calls.last else {
      Issue.record("pas de mise à jour")
      return
    }
    #expect(state.remaining == 1)
    #expect(state.total == 2)
    #expect(state.nextItemLabel == labels[1])
  }

  @Test func undoAndUncheckGoBack() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    session.toggle(try row(session, "lait"))
    #expect(activity.states.last?.remaining == 0)
    session.performUndo()
    #expect(activity.states.last?.remaining == 1)
    #expect(activity.states.last?.nextItemLabel == "lait")
  }

  @Test func addingAndMarkingNotFoundChangeTheCount() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()

    session.input = "pain"
    await session.submit()
    #expect(activity.states.last?.remaining == 2)
    #expect(activity.states.last?.total == 2)

    session.markNotFound(try row(session, "pain"))
    #expect(activity.states.last?.remaining == 1)
    #expect(activity.states.last?.total == 1)
  }

  @Test func anUnchangedStateIsNotSentAgain() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    #expect(activity.calls.count == 1)

    // Relectures, tris et interactions qui ne changent rien à l'état : rien ne part.
    session.syncDidChange()
    session.syncDidChange()
    session.setScrolling(true)
    session.setScrolling(false)
    await session.waitUntilSettled()
    #expect(activity.calls.count == 1)

    // Preuve que l'enregistreur voit bien un vrai changement.
    session.toggle(try row(session, "lait"))
    #expect(activity.calls.count == 2)
  }

  @Test func finishingEndsTheActivityWithAFinalState() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    session.toggle(try row(session, "lait"))
    session.finish(keepRemaining: true)

    guard case .end(let state)? = activity.calls.last else {
      Issue.record("pas de fin")
      return
    }
    #expect(state.isFinished)
    #expect(activity.endCount == 1)
    let count = activity.calls.count
    session.syncDidChange()
    #expect(activity.calls.count == count)
  }

  @Test func anExpiredVisitEndsTheActivity() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    harness.date = t0.addingTimeInterval(600)
    session.toggle(try row(session, "lait"))
    harness.date = t0.addingTimeInterval(600 + ShoppingSession.expiry)
    session.foregrounded()

    #expect(session.expired)
    #expect(activity.endCount == 1)
    guard case .end? = activity.calls.last else {
      Issue.record("pas de fin")
      return
    }
  }

  @Test func resumingAnExpiredVisitEndsTheOrphanActivityWithoutStartingOne() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let first = harness.session()
    await first.start()
    harness.date = t0.addingTimeInterval(600)
    first.toggle(try row(first, "lait"))
    let visit = try #require(try harness.visits.openVisit())

    // L'app était fermée plus de 45 min : la visite expire à la reprise.
    harness.date = t0.addingTimeInterval(600 + ShoppingSession.expiry + 1)
    let activity = RecordingActivity()
    let resumed = harness.session(activity: activity)
    await resumed.resume(visit: visit)

    #expect(resumed.expired)
    #expect(activity.calls.count == 1)
    guard case .end(let state)? = activity.calls.first else {
      Issue.record("l'activité orpheline n'est pas terminée")
      return
    }
    #expect(state.isFinished)
  }

  @Test func comingBackToTheForegroundRetriesTheActivity() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    session.foregrounded()
    #expect(activity.retryCount == 1)
  }

  @Test func theAttributesCarryTheVisit() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    guard case .start(let attributes, _)? = activity.calls.first else {
      Issue.record("pas de démarrage")
      return
    }
    #expect(attributes.visitId == session.visitId)
    #expect(attributes.visitId != nil)
  }

  @Test func resumingStartsTheActivityAgainWithTheRemainingItems() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let first = harness.session()
    await first.start()
    first.toggle(try row(first, "lait"))
    await first.waitUntilSettled()

    let activity = RecordingActivity()
    let resumed = harness.session(activity: activity)
    await resumed.resume(visit: try #require(try harness.visits.openVisit()))
    guard case .start(_, let state)? = activity.calls.first else {
      Issue.record("pas de démarrage")
      return
    }
    #expect(state.remaining == 1)
    #expect(state.total == 2)
    #expect(state.nextItemLabel == "tomates")
  }

  @Test func withoutStoreTheActivityStillRuns() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(withStore: false, activity: activity)
    await session.start()
    #expect(activity.calls.count == 1)
  }
}

// MARK: - Reprise et nettoyage des Live Activities

private actor FakeBackend: ActivityBackend {
  enum Call: Equatable {
    case request(UUID?)
    case update(String)
    case end(String, immediate: Bool)
  }

  private var infos: [ActivityInfo]
  private(set) var calls: [Call] = []
  private(set) var staleDates: [Date?] = []
  private let requestResult: String?
  /// Réponse quand `requestResult` vaut `nil`.
  private let refusal: ActivityRequestResult
  /// Refus passagers à renvoyer avant d'accepter.
  private var failuresLeft: Int
  private var requestCount = 0

  init(
    _ infos: [ActivityInfo] = [], requestResult: String? = "new", refusal: ActivityRequestResult = .unavailable,
    failures: Int = 0
  ) {
    self.infos = infos
    self.requestResult = requestResult
    self.refusal = refusal
    failuresLeft = failures
  }

  func current() -> [ActivityInfo] { infos }

  func request(
    attributes: ShoppingActivityAttributes, state: ActivityState, staleDate: Date?
  ) -> ActivityRequestResult {
    calls.append(.request(attributes.visitId))
    staleDates.append(staleDate)
    if failuresLeft > 0 {
      failuresLeft -= 1
      return .failed
    }
    guard let requestResult else { return refusal }
    // « new », puis « new-2 »… : chaque activité créée a son identifiant.
    requestCount += 1
    let id = requestCount == 1 ? requestResult : "\(requestResult)-\(requestCount)"
    infos.append(
      ActivityInfo(id: id, visitId: attributes.visitId, isActive: true, attributes: attributes, state: state))
    return .started(id)
  }

  func update(id: String, state: ActivityState, staleDate: Date?) -> Bool {
    calls.append(.update(id))
    staleDates.append(staleDate)
    return infos.contains { $0.id == id && $0.isActive }
  }

  /// Comme ActivityKit : une activité terminée passe en `.ended` et reste listée jusqu'à son retrait.
  func end(id: String, state: ActivityState?, policy: ActivityEndPolicy) {
    calls.append(.end(id, immediate: policy == .immediate))
    guard let index = infos.firstIndex(where: { $0.id == id }) else { return }
    let info = infos[index]
    if policy == .immediate {
      infos.remove(at: index)
    } else {
      infos[index] = ActivityInfo(
        id: info.id, visitId: info.visitId, isActive: false, attributes: info.attributes, state: state ?? info.state)
    }
  }

  /// La personne écarte l'activité de l'écran verrouillé : le système la retire.
  func dismissByUser(_ id: String) {
    infos.removeAll { $0.id == id }
  }
}

/// Visites écartées, en mémoire.
private final class MemoryDismissals: ActivityDismissals, @unchecked Sendable {
  private var visits: Set<UUID> = []
  func contains(_ visitId: UUID) -> Bool { visits.contains(visitId) }
  func remember(_ visitId: UUID) { visits.insert(visitId) }
}

@Suite @MainActor struct ActivityControllerTests {
  private let visitA = UUID()
  private let visitB = UUID()
  private let state = ActivityState(remaining: 2, total: 3)

  private func attributes(_ visit: UUID?) -> ShoppingActivityAttributes {
    ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: nil)
  }

  @Test func theActivityOfTheSameVisitIsReused() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: visitA, isActive: true)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.update("a")])
  }

  @Test func theActivityOfAnotherVisitIsReplacedThenEnded() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: visitA, isActive: true)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    // La neuve d'abord : l'écran verrouillé n'est jamais vide entre les deux.
    #expect(await backend.calls == [.request(visitB), .end("a", immediate: true)])
  }

  @Test func anEndedActivityOfTheSameVisitIsNotReused() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: visitA, isActive: false)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .end("a", immediate: true)])
  }

  @Test func aVisitlessSessionNeverReusesAnActivity() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: nil, isActive: true)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(nil), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(nil), .end("a", immediate: true)])
  }

  @Test func extraActivitiesAreEndedAndOnlyOneIsKept() async {
    let backend = FakeBackend([
      ActivityInfo(id: "a", visitId: visitA, isActive: true), ActivityInfo(id: "b", visitId: visitA, isActive: true),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.update("a"), .end("b", immediate: true)])
  }

  @Test func orphansAreEndedAtLaunchExceptTheOpenVisit() async {
    let backend = FakeBackend([
      ActivityInfo(id: "a", visitId: visitA, isActive: true), ActivityInfo(id: "b", visitId: visitB, isActive: true),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.endAll(except: visitA)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.end("b", immediate: true)])

    controller.endAll(except: nil)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.end("b", immediate: true), .end("a", immediate: true)])
  }

  /// #52 : la relance ne doit pas effacer le message de fin d'une visite terminée.
  @Test func theFinalMessageOfAFinishedVisitSurvivesARelaunch() async {
    let backend = FakeBackend()
    let first = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    first.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await first.waitUntilIdle()
    first.end(state: ActivityState(remaining: 0, total: 3, isFinished: true))
    await first.waitUntilIdle()
    #expect(await backend.current().map(\.isActive) == [false])

    // Lancement suivant : aucune visite ouverte, les orphelines partent, pas « Courses terminées ».
    let relaunched = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    relaunched.endAll(except: nil)
    await relaunched.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .end("new", immediate: false)])
    #expect(await backend.current().count == 1)
  }

  @Test func endingOrphansLeavesEndedActivitiesAlone() async {
    let backend = FakeBackend([
      ActivityInfo(id: "done", visitId: visitA, isActive: false),
      ActivityInfo(id: "b", visitId: visitB, isActive: true),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.endAll(except: nil)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.end("b", immediate: true)])
  }

  /// #52 : écartée par la personne, l'activité ne revient pas, et rien ne part plus vers ActivityKit.
  @Test func anActivityDismissedByThePersonStaysDismissed() async {
    let backend = FakeBackend()
    let dismissals = MemoryDismissals()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: dismissals)
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    await backend.dismissByUser("new")

    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    controller.update(state: ActivityState(remaining: 0, total: 3), lastActivity: t0)
    controller.retryIfNeeded()
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .update("new")])
    #expect(dismissals.contains(visitA))

    // App relancée sur la même visite : toujours rien. Une autre visite en a une.
    let relaunched = ActivityKitShoppingActivity(backend: backend, dismissals: dismissals)
    relaunched.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    relaunched.retryIfNeeded()
    await relaunched.waitUntilIdle()
    #expect(await backend.calls.count == 2)
    relaunched.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    await relaunched.waitUntilIdle()
    #expect(await backend.calls.last == .request(visitB))
  }

  /// Sans visite (pas de magasin), le geste vaut pour ce mode courses seulement.
  @Test func aDismissedVisitlessActivityComesBackWithTheNextShopping() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(nil), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    await backend.dismissByUser("new")
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    controller.update(state: ActivityState(remaining: 0, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(nil), .update("new")])

    controller.start(attributes: attributes(nil), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls.last == .request(nil))
  }

  /// #52 : après une reprise de compte, la session redémarre l'activité sous la nouvelle visite ; la neuve paraît
  /// avant que l'ancienne parte.
  @Test func aRekeyedVisitReplacesItsActivityWithoutAGap() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    controller.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(
      await backend.calls == [.request(visitA), .request(visitB), .end("new", immediate: true), .update("new-2")])
  }

  @Test func endingWithoutAKnownActivityEndsTheOneLeftByAPreviousLaunch() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: visitA, isActive: true)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.end(state: ActivityState(remaining: 0, total: 0, isFinished: true))
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.end("a", immediate: false)])
  }

  @Test func aPassingRefusalIsRetriedWithTheNextUpdate() async {
    let backend = FakeBackend(failures: 1)
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .request(visitA)])
  }

  /// Plafond d'activités : la neuve est refusée tant que l'ancienne est là. L'ancienne part, puis on redemande.
  @Test func aRefusalWithActivitiesLeftEndsThemThenAsksAgain() async {
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: visitA, isActive: true)], failures: 1)
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitB), .end("a", immediate: true), .request(visitB)])
  }

  /// Reprise de compte : une activité écartée le reste sous le nouvel identifiant de la visite.
  @Test func aDismissalFollowsTheRekeyedVisit() async {
    let backend = FakeBackend()
    let dismissals = MemoryDismissals()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: dismissals)
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    await backend.dismissByUser("new")
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()

    controller.rekeyed(from: visitA, to: visitB)
    controller.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .update("new")])
  }

  /// #52 : activités désactivées, les mises à jour ne retentent pas ; seul le retour au premier plan le fait.
  @Test func aRefusedRequestIsRetriedOnForegroundOnly() async {
    let refusing = FakeBackend(requestResult: nil)
    let controller = ActivityKitShoppingActivity(backend: refusing, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    controller.update(state: ActivityState(remaining: 0, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await refusing.calls == [.request(visitA)])
    controller.retryIfNeeded()
    controller.update(state: ActivityState(remaining: 0, total: 3), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await refusing.calls == [.request(visitA), .request(visitA)])
  }

  @Test func updatesAfterTheEndAreIgnored() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    controller.end(state: state)
    controller.update(state: state, lastActivity: t0)
    controller.retryIfNeeded()
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.request(visitA), .end("new", immediate: false)])
  }
}

@Suite struct ActivityStateEncodingTests {
  @Test func aMissingFieldFallsBackToADefault() throws {
    let json = Data(#"{"remaining": 2}"#.utf8)
    let state = try JSONDecoder().decode(ActivityState.self, from: json)
    #expect(state == ActivityState(remaining: 2, total: 0))
  }

  @Test func anUnknownFieldIsIgnored() throws {
    let json = Data(#"{"remaining": 1, "total": 4, "nextItemLabel": "lait", "future": true}"#.utf8)
    let state = try JSONDecoder().decode(ActivityState.self, from: json)
    #expect(state.nextItemLabel == "lait")
  }

  @Test func aLongLabelIsTruncated() {
    let long = String(repeating: "x", count: 500)
    let state = ActivityState.make(
      toBuy: [ShoppingRow(id: UUID(), label: long, quantity: nil, isChecked: false, aisleId: "a")], basket: [],
      categoryLabel: { _ in long })
    #expect(state.nextItemLabel?.count == ActivityState.maxLabelLength)
    #expect(state.nextCategoryLabel?.count == ActivityState.maxLabelLength)
  }
}

// MARK: - Parité avec Android (A8 à A10) : introuvables, double coche, péremption, « Cocher le suivant »

extension Harness {
  /// Visite ouverte dans un autre magasin, avec une coche à `checkedAt`.
  func visitElsewhere(startedAt: Date = t0, checkedAt: Date? = nil) throws -> UUID {
    let visit = try visits.startVisit(storeId: UUID(), listId: listId, listWasSorted: false, at: startedAt)
    let id = visit.id
    if let checkedAt {
      try visits.addCheck(visitId: id, itemId: UUID(), subject: .category("other"), checkedAt: checkedAt)
    }
    return id
  }

  func item(_ id: UUID) throws -> ListItem {
    try #require(try lists.items(listId: listId).first { $0.id == id })
  }
}

@Suite(.serialized) struct VisitParityTests {
  // M3 (#54) : une visite close sans réponse à « garder ou retirer » garde les articles, introuvables compris.

  @MainActor @Test func aNewVisitPutsTheUncheckedNotFoundItemsBackToBuy() throws {
    let harness = try Harness()
    let missing = try harness.add("lait")
    let checked = try harness.add("pain")
    try harness.lists.setNotFound(itemId: missing, notFoundAt: t0, at: t0)
    try harness.lists.setNotFound(itemId: checked, notFoundAt: t0, at: t0)
    try harness.lists.setChecked(itemId: checked, checkedAt: t0, at: t0)

    try harness.visits.startVisit(storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    #expect(try harness.item(missing).notFoundAt == nil)
    // Seuls les articles non cochés reviennent : un article coché reste tel quel.
    #expect(try harness.item(checked).notFoundAt == t0)
  }

  @MainActor @Test func aVisitClosedByANewOneEndsAtItsLastCheck() throws {
    let harness = try Harness()
    let missing = try harness.add("lait")
    let other = try harness.visitElsewhere(checkedAt: t0.addingTimeInterval(120))
    try harness.lists.setNotFound(itemId: missing, notFoundAt: t0.addingTimeInterval(60), at: t0)

    let next = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0.addingTimeInterval(3600))
    #expect(next.id != other)
    #expect(try harness.visits.visit(id: other)?.endedAt == t0.addingTimeInterval(120))
    #expect(try harness.item(missing).notFoundAt == nil)
    #expect(try harness.outbox(.closeVisit).count == 1)
  }

  @MainActor @Test func aStaleVisitIsReplacedInsteadOfResumed() throws {
    let harness = try Harness()
    let visit = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    let staleId = visit.id
    let lastCheck = t0.addingTimeInterval(300)
    try harness.visits.addCheck(visitId: staleId, itemId: UUID(), subject: .category("other"), checkedAt: lastCheck)

    // Encore active : reprise.
    let resumed = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false,
      at: lastCheck.addingTimeInterval(ShoppingSession.expiry - 1), staleAfter: ShoppingSession.expiry)
    #expect(resumed.id == staleId)

    // Périmée, comptée depuis la dernière coche et non depuis le début : une neuve commence.
    let fresh = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false,
      at: lastCheck.addingTimeInterval(ShoppingSession.expiry), staleAfter: ShoppingSession.expiry)
    #expect(fresh.id != staleId)
    #expect(try harness.visits.visit(id: staleId)?.endedAt == lastCheck)
    #expect(try harness.visits.openVisit()?.id == fresh.id)
  }

  @MainActor @Test func abandoningClosesAtTheLastCheckOnlyWhenStale() throws {
    let harness = try Harness()
    let missing = try harness.add("lait")
    let lastCheck = t0.addingTimeInterval(600)
    let visit = try harness.visitElsewhere(checkedAt: lastCheck)
    try harness.lists.setNotFound(itemId: missing, notFoundAt: t0, at: t0)

    let early = lastCheck.addingTimeInterval(ShoppingSession.expiry - 1)
    #expect(try !harness.visits.abandonVisit(id: visit, at: early, staleAfter: ShoppingSession.expiry))
    #expect(try harness.visits.visit(id: visit)?.endedAt == nil)
    #expect(try harness.item(missing).notFoundAt == t0)

    let late = lastCheck.addingTimeInterval(ShoppingSession.expiry)
    #expect(try harness.visits.abandonVisit(id: visit, at: late, staleAfter: ShoppingSession.expiry))
    #expect(try harness.visits.visit(id: visit)?.endedAt == lastCheck)
    #expect(try harness.item(missing).notFoundAt == nil)

    // Déjà close, ou disparue : sans effet ni erreur.
    #expect(try !harness.visits.abandonVisit(id: visit, at: late, staleAfter: 0))
    #expect(try !harness.visits.abandonVisit(id: UUID(), at: late, staleAfter: 0))
  }

  @MainActor @Test func abandoningAVisitWithoutCheckDeletesIt() throws {
    let harness = try Harness()
    let visit = try harness.visitElsewhere()
    #expect(try harness.visits.abandonVisit(id: visit, at: t0, staleAfter: 0))
    #expect(try harness.visits.visit(id: visit) == nil)
    #expect(try harness.outbox(.closeVisit).isEmpty)
  }

  @MainActor @Test func theLastActivityIsTheLastCheckOtherwiseTheStart() throws {
    let harness = try Harness()
    let visit = try harness.visitElsewhere(startedAt: t0)
    #expect(try harness.visits.lastActivity(visitId: visit) == t0)
    try harness.visits.addCheck(
      visitId: visit, itemId: UUID(), subject: .category("other"), checkedAt: t0.addingTimeInterval(90))
    #expect(try harness.visits.lastActivity(visitId: visit) == t0.addingTimeInterval(90))
    #expect(try harness.visits.lastActivity(visitId: UUID()) == nil)
  }

  // Double coche refusée.

  @MainActor @Test func anItemAlreadyCheckedIsRefusedOnce() throws {
    let harness = try Harness()
    let item = try harness.add("lait")
    let visit = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    let visitId = visit.id
    try harness.visits.checkItem(
      visitId: visitId, itemId: item, subject: .category("dairy"), checkedAt: t0, sendAfter: 0)
    #expect(throws: RepositoryError.alreadyChecked(item)) {
      try harness.visits.checkItem(
        visitId: visitId, itemId: item, subject: .category("dairy"), checkedAt: t0.addingTimeInterval(1), sendAfter: 0)
    }
    #expect(try harness.visits.checks(visitId: visitId).count == 1)
    #expect(try harness.outbox(.insertChecks).count == 1)
  }
}

@Suite(.serialized) @MainActor struct ShoppingParityTests {
  @Test func aNewVisitStartsWithoutTheNotFoundLeftByAnExpiredOne() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let first = harness.session()
    await first.start()
    first.toggle(try row(first, "lait"))
    first.markNotFound(try row(first, "tomates"))
    #expect(first.notFound.map(\.label) == ["tomates"])
    // Expirée, puis l'app est tuée avant la réponse à « garder ou retirer ».
    harness.date = t0.addingTimeInterval(ShoppingSession.expiry)
    first.foregrounded()
    #expect(first.expired)

    harness.date = t0.addingTimeInterval(2 * ShoppingSession.expiry)
    let next = harness.session()
    await next.start()
    #expect(next.notFound.isEmpty)
    #expect(next.toBuy.map(\.label) == ["tomates"])
  }

  @Test func aStaleOpenVisitIsNotResumedByTheShoppingMode() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let first = harness.session()
    await first.start()
    harness.date = t0.addingTimeInterval(60)
    first.toggle(try row(first, "lait"))
    let staleId = try #require(first.visitId)

    harness.date = t0.addingTimeInterval(60 + ShoppingSession.expiry)
    let next = harness.session()
    await next.start()
    #expect(next.visitId != staleId)
    #expect(try harness.visits.visit(id: staleId)?.endedAt == t0.addingTimeInterval(60))
  }

  @Test func checkingAnItemCheckedElsewhereMakesOneCheckWithoutError() async throws {
    let harness = try Harness()
    let id = try harness.add("lait")
    try harness.add("tomates")
    let session = harness.session()
    await session.start()
    let visitId = try #require(session.visitId)
    let stale = try row(session, "lait")
    // Coché par la Live Activity pendant que l'écran montrait encore la ligne à prendre.
    try harness.visits.checkItem(
      visitId: visitId, itemId: id, subject: .category("dairy"), checkedAt: t0, sendAfter: 0)

    session.toggle(stale)
    #expect(session.errorMessage == nil)
    #expect(session.undo == nil)
    #expect(try harness.visits.checks(visitId: visitId).count == 1)
    #expect(session.basket.map(\.label) == ["lait"])
    #expect(session.toBuy.map(\.label) == ["tomates"])
  }

  @Test func theActivityGoesStaleFromTheLastCheck() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    #expect(activity.lastActivities == [t0])

    harness.date = t0.addingTimeInterval(600)
    session.toggle(try row(session, "lait"))
    #expect(activity.lastActivities.last == t0.addingTimeInterval(600))

    // Un retour au premier plan, sans coche, ne repousse rien.
    harness.date = t0.addingTimeInterval(1200)
    session.foregrounded()
    #expect(activity.lastActivities.count == 2)
  }

  @Test func theStateCarriesTheDisplayedOrder() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    let state = try #require(activity.states.last)
    #expect(state.pendingItemIds == session.toBuy.map(\.id))
    #expect(state.nextItemId == session.toBuy.first?.id)
  }
}

@Suite @MainActor struct LaunchResumeParityTests {
  /// Environnement de l'app sur un store en mémoire. Rien n'y démarre de Live Activity : chaque cas abandonne la
  /// visite avant d'ouvrir un mode courses.
  private func environment() throws -> (AppEnvironment, Harness) {
    let harness = try Harness()
    return (try AppEnvironment(container: harness.container), harness)
  }

  @Test func aStaleVisitIsClosedAtItsLastCheckAndNothingReopens() async throws {
    let (environment, harness) = try environment()
    let missing = try harness.add("lait")
    let lastCheck = t0.addingTimeInterval(300)
    let visit = try harness.visitElsewhere(checkedAt: lastCheck)
    try harness.lists.setNotFound(itemId: missing, notFoundAt: t0, at: t0)

    let session = await environment.resumeShopping(now: lastCheck.addingTimeInterval(ShoppingSession.expiry))
    #expect(session == nil)
    #expect(try harness.visits.visit(id: visit)?.endedAt == lastCheck)
    #expect(try harness.item(missing).notFoundAt == nil)
  }

  /// #52 : liste disparue pendant que l'app était fermée. La visite est close, son activité retirée ; le message de
  /// fin d'une visite déjà terminée reste.
  @Test func aVisitWhoseListIsGoneLosesItsActivityAtLaunch() async throws {
    let harness = try Harness()
    let visit = try harness.visitElsewhere(checkedAt: t0.addingTimeInterval(300))
    let backend = FakeBackend([
      ActivityInfo(id: "done", visitId: UUID(), isActive: false), ActivityInfo(id: "a", visitId: visit, isActive: true),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    let environment = try AppEnvironment(container: harness.container, shoppingActivity: controller)
    try harness.lists.deleteList(id: harness.listId, at: t0.addingTimeInterval(400))

    let session = await environment.resumeShopping(now: t0.addingTimeInterval(500))
    environment.endOrphanActivities(keeping: session?.visitId)
    await controller.waitUntilIdle()
    #expect(session == nil)
    #expect(await backend.calls == [.end("a", immediate: true)])
  }

  /// #52 : aucune visite ouverte au lancement (crash pendant la fin, visite close ailleurs) : l'activité part.
  @Test func withoutAnOpenVisitTheOrphanActivityEndsAtLaunch() async throws {
    let harness = try Harness()
    let backend = FakeBackend([ActivityInfo(id: "a", visitId: UUID(), isActive: true)])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    let environment = try AppEnvironment(container: harness.container, shoppingActivity: controller)

    let session = await environment.resumeShopping(now: t0)
    environment.endOrphanActivities(keeping: session?.visitId)
    await controller.waitUntilIdle()
    #expect(session == nil)
    #expect(await backend.calls == [.end("a", immediate: true)])
  }

  /// La visite reprise garde son activité, mise à jour sur place ; une autre part.
  @Test func theResumedVisitKeepsItsActivityAtLaunch() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let visit = try harness.visitElsewhere(checkedAt: t0.addingTimeInterval(60))
    let backend = FakeBackend([
      ActivityInfo(id: "a", visitId: visit, isActive: true), ActivityInfo(id: "b", visitId: UUID(), isActive: true),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    let environment = try AppEnvironment(container: harness.container, shoppingActivity: controller)

    let session = await environment.resumeShopping(now: t0.addingTimeInterval(120))
    environment.endOrphanActivities(keeping: session?.visitId)
    await controller.waitUntilIdle()
    #expect(session?.visitId == visit)
    let calls = await backend.calls
    #expect(calls.contains(.update("a")))
    #expect(!calls.contains(.end("a", immediate: true)))
    #expect(calls.contains(.end("b", immediate: true)))
  }

  @Test func aVisitWhoseListIsGoneIsClosedAtItsLastCheck() async throws {
    let (environment, harness) = try environment()
    let lastCheck = t0.addingTimeInterval(300)
    let visit = try harness.visitElsewhere(checkedAt: lastCheck)
    try harness.lists.deleteList(id: harness.listId, at: t0.addingTimeInterval(400))

    let session = await environment.resumeShopping(now: t0.addingTimeInterval(500))
    #expect(session == nil)
    #expect(try harness.visits.visit(id: visit)?.endedAt == lastCheck)
  }
}

// MARK: - « Cocher le suivant »

@Suite struct ActivityReconciliationTests {
  private func describe(_ item: ListItem) -> (label: String, aisleId: String, aisle: String?) {
    (item.label, item.categoryId, "Rayon")
  }

  @MainActor @Test func theDisplayedOrderIsKeptAndTakenItemsLeave() throws {
    let harness = try Harness()
    let a = try harness.add("lait")
    let b = try harness.add("pain")
    let c = try harness.add("tomates")
    let state = ActivityState(remaining: 3, total: 3, nextItemLabel: "tomates", pendingItemIds: [c, a, b])
    try harness.lists.setChecked(itemId: c, checkedAt: t0, at: t0)

    let refreshed = state.reconciled(items: try harness.lists.items(listId: harness.listId), describe: describe)
    #expect(refreshed.pendingItemIds == [a, b])
    #expect(refreshed.nextItemLabel == "lait")
    #expect(refreshed.nextCategoryLabel == "Rayon")
    #expect(refreshed.nextAisleId == "dairy")
    #expect(refreshed.remaining == 2)
    #expect(refreshed.total == 3)
  }

  @MainActor @Test func notFoundItemsLeaveAndOthersFollowInListOrder() throws {
    let harness = try Harness()
    let a = try harness.add("lait")
    let b = try harness.add("pain")
    let c = try harness.add("tomates")
    try harness.lists.setNotFound(itemId: c, notFoundAt: t0, at: t0)
    // Le pain n'était pas dans la file (au-delà du plafond, ou ajouté ailleurs).
    let state = ActivityState(remaining: 2, total: 3, pendingItemIds: [c, a])

    let refreshed = state.reconciled(items: try harness.lists.items(listId: harness.listId), describe: describe)
    #expect(refreshed.pendingItemIds == [a, b])
    #expect(refreshed.remaining == 2)
    #expect(refreshed.total == 2)
  }

  @Test func theQueueIsCapped() {
    let state = ActivityState.make(
      toBuy: rows((0..<50).map { "article \($0)" }), basket: [], categoryLabel: { _ in nil })
    #expect(state.pendingItemIds.count == ActivityState.maxPendingItems)
    #expect(state.remaining == 50)
    let finished = ActivityState.make(toBuy: rows(["lait"]), basket: [], categoryLabel: { _ in nil }, isFinished: true)
    #expect(finished.nextItemId == nil)
  }

  @Test func theQueueSurvivesEncodingAndAnOldStateHasNone() throws {
    let state = ActivityState(remaining: 1, total: 1, nextItemLabel: "lait", pendingItemIds: [UUID()])
    #expect(try JSONDecoder().decode(ActivityState.self, from: JSONEncoder().encode(state)) == state)
    let old = try JSONDecoder().decode(ActivityState.self, from: Data(#"{"remaining": 1, "total": 1}"#.utf8))
    #expect(old.nextItemId == nil)
  }
}

@Suite(.serialized) @MainActor struct CheckNextTests {
  private func actions(
    _ harness: Harness, activity: RecordingActivity, session: ShoppingSession? = nil
  ) -> ShoppingActivityActions {
    ShoppingActivityActions(
      lists: harness.lists, visits: harness.visits, stores: harness.stores, categories: harness.categories,
      analyzer: harness.analyzer, activity: activity, session: { session }, now: { [harness] in harness.date },
      scheduleSync: {
        // Aucune tâche système à planifier dans les tests.
      })
  }

  /// Visite ouverte avec deux articles ; l'activité affiche `order`.
  private func seed(_ harness: Harness) throws -> (visit: UUID, milk: UUID, bread: UUID) {
    let milk = try harness.add("lait")
    let bread = try harness.add("pain")
    let visit = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    return (visit.id, milk, bread)
  }

  @Test func theDisplayedItemIsCheckedAndTheNextOneShownWithoutTheApp() async throws {
    let harness = try Harness()
    let (visit, milk, bread) = try seed(harness)
    let activity = RecordingActivity()
    activity.restored[visit] = ActivityState(
      remaining: 2, total: 2, nextItemLabel: "lait", pendingItemIds: [milk, bread])
    harness.date = t0.addingTimeInterval(60)

    await actions(harness, activity: activity).checkNext(visitId: visit, itemId: milk)
    let checks = try harness.visits.checks(visitId: visit)
    #expect(checks.map(\.itemId) == [milk])
    // Même retenue que l'écran : rien ne part avant la fin du délai d'annulation.
    #expect(try harness.outbox(.insertChecks).first?.nextAttemptAt == t0.addingTimeInterval(65))
    let state = try #require(activity.states.last)
    #expect(state.nextItemId == bread)
    #expect(state.nextItemLabel == "pain")
    #expect(state.nextCategoryLabel != nil)
    #expect(state.remaining == 1)
    #expect(activity.lastActivities.last == t0.addingTimeInterval(60))
  }

  @Test func aSecondTapOnTheSameItemDoesNothing() async throws {
    let harness = try Harness()
    let (visit, milk, bread) = try seed(harness)
    let activity = RecordingActivity()
    let shown = ActivityState(remaining: 2, total: 2, pendingItemIds: [milk, bread])
    activity.restored[visit] = shown
    let checkNext = actions(harness, activity: activity)
    await checkNext.checkNext(visitId: visit, itemId: milk)
    // Le second toucher arrive avant que l'affichage ait changé : l'article est déjà coché.
    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(try harness.visits.checks(visitId: visit).count == 1)

    // Après l'affichage suivant, un toucher dépassé sur le lait est ignoré.
    activity.restored[visit] = activity.states.last
    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(try harness.visits.checks(visitId: visit).count == 1)
  }

  @Test func anItemNoLongerShownOrNotFoundIsNotChecked() async throws {
    let harness = try Harness()
    let (visit, milk, bread) = try seed(harness)
    let activity = RecordingActivity()
    activity.restored[visit] = ActivityState(remaining: 1, total: 2, pendingItemIds: [milk])
    let checkNext = actions(harness, activity: activity)
    await checkNext.checkNext(visitId: visit, itemId: bread)
    #expect(activity.calls.isEmpty)

    // Passé introuvable ailleurs : rien n'est coché, et l'affichage suit la base au lieu de garder le lait.
    try harness.lists.setNotFound(itemId: milk, notFoundAt: t0, at: t0)
    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(try harness.visits.checks(visitId: visit).isEmpty)
    #expect(activity.states.last?.nextItemId == bread)
    #expect(activity.states.last?.remaining == 1)
  }

  @Test func aStaleClosedOrUnknownVisitIsLeftAlone() async throws {
    let harness = try Harness()
    let (visit, milk, _) = try seed(harness)
    let activity = RecordingActivity()
    activity.restored[visit] = ActivityState(remaining: 2, total: 2, pendingItemIds: [milk])
    let checkNext = actions(harness, activity: activity)

    // Rien ne suit cette visite.
    await checkNext.checkNext(visitId: UUID(), itemId: milk)
    #expect(activity.endAllKeeping.isEmpty)
    // Périmée : une coche ne la ranime pas, et l'activité part.
    harness.date = t0.addingTimeInterval(ShoppingSession.expiry)
    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(activity.endAllKeeping == [nil])
    // Close : l'activité part aussi.
    harness.date = t0
    try harness.visits.closeVisit(id: visit, at: t0)
    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(activity.endAllKeeping == [nil, nil])
    #expect(try harness.visits.checks(visitId: visit).isEmpty)
    #expect(try harness.item(milk).checkedAt == nil)
  }

  /// App relancée par le système : le vrai contrôleur reprend l'activité laissée, puis la met à jour.
  @Test func theActivityLeftByAPreviousLaunchFollowsTheCheck() async throws {
    let harness = try Harness()
    let (visit, milk, bread) = try seed(harness)
    let attributes = ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: "Leclerc Auch")
    let shown = ActivityState(remaining: 2, total: 2, nextItemLabel: "lait", pendingItemIds: [milk, bread])
    let backend = FakeBackend([
      ActivityInfo(id: "a", visitId: visit, isActive: true, attributes: attributes, state: shown)
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    harness.date = t0.addingTimeInterval(60)
    let checkNext = ShoppingActivityActions(
      lists: harness.lists, visits: harness.visits, stores: harness.stores, categories: harness.categories,
      analyzer: harness.analyzer, activity: controller, session: { nil }, now: { [harness] in harness.date },
      scheduleSync: {
        // Aucune tâche système à planifier dans les tests.
      })

    await checkNext.checkNext(visitId: visit, itemId: milk)
    #expect(try harness.visits.checks(visitId: visit).map(\.itemId) == [milk])
    #expect(await backend.calls == [.update("a")])
    #expect(await backend.staleDates == [t0.addingTimeInterval(60 + ShoppingSession.expiry)])
    #expect(await controller.restore(visitId: visit)?.nextItemId == bread)
  }

  @Test func anOpenShoppingModeLearnsTheCheckAndKeepsItsOrder() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("tomates")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    let visit = try #require(session.visitId)
    let first = try #require(session.toBuy.first)
    activity.restored[visit] = activity.states.last

    await actions(harness, activity: activity, session: session).checkNext(visitId: visit, itemId: first.id)
    #expect(session.basket.map(\.id) == [first.id])
    #expect(session.undo == nil)
    #expect(session.errorMessage == nil)
    #expect(activity.states.last?.nextItemId == session.toBuy.first?.id)
    #expect(activity.states.last?.remaining == 1)

    // L'écran montrait encore la ligne : la toucher ne la coche pas une seconde fois.
    session.toggle(first)
    #expect(try harness.visits.checks(visitId: visit).count == 1)
    #expect(session.errorMessage == nil)
  }
}

@MainActor
private final class RecordingHandler: CheckNextItemHandling {
  private(set) var calls: [(UUID, UUID)] = []
  func checkNext(visitId: UUID, itemId: UUID) async { calls.append((visitId, itemId)) }
}

@Suite(.serialized) @MainActor struct CheckNextIntentTests {
  @Test func theIntentReachesTheAppHandler() async throws {
    let previous = CheckNextItemRouter.handler
    defer { CheckNextItemRouter.handler = previous }
    let handler = RecordingHandler()
    CheckNextItemRouter.handler = handler
    let visit = UUID()
    let item = UUID()

    _ = try await CheckNextItemIntent(visitId: visit, itemId: item).perform()
    #expect(handler.calls.count == 1)
    #expect(handler.calls.first?.0 == visit)
    #expect(handler.calls.first?.1 == item)

    var broken = CheckNextItemIntent()
    broken.visitId = "pas un identifiant"
    broken.itemId = item.uuidString
    _ = try await broken.perform()
    #expect(handler.calls.count == 1)
  }
}

@Suite @MainActor struct ActivityTimingTests {
  @Test func theStaleDateFollowsTheLastCheck() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, now: { t0.addingTimeInterval(9999) })
    let visit = UUID()
    let attributes = ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: nil)
    controller.start(attributes: attributes, state: ActivityState(remaining: 1, total: 1), lastActivity: t0)
    controller.update(state: ActivityState(remaining: 0, total: 1), lastActivity: t0.addingTimeInterval(60))
    await controller.waitUntilIdle()
    #expect(
      await backend.staleDates == [
        t0.addingTimeInterval(ShoppingSession.expiry), t0.addingTimeInterval(60 + ShoppingSession.expiry),
      ])
  }

  @Test func anActivityLeftByAPreviousLaunchIsRestoredThenUpdated() async {
    let visit = UUID()
    let attributes = ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: nil)
    let shown = ActivityState(remaining: 2, total: 2, pendingItemIds: [UUID()])
    let backend = FakeBackend([
      ActivityInfo(id: "old", visitId: UUID(), isActive: true, attributes: attributes, state: shown),
      ActivityInfo(id: "a", visitId: visit, isActive: true, attributes: attributes, state: shown),
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    #expect(await controller.restore(visitId: UUID()) == nil)
    #expect(await controller.restore(visitId: visit) == shown)
    controller.update(state: ActivityState(remaining: 1, total: 2), lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls == [.update("a")])
  }

  @Test func anEndedActivityIsNotRestored() async {
    let visit = UUID()
    let attributes = ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: nil)
    let backend = FakeBackend([
      ActivityInfo(
        id: "a", visitId: visit, isActive: false, attributes: attributes, state: ActivityState(remaining: 1, total: 1))
    ])
    #expect(
      await ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals()).restore(visitId: visit) == nil
    )
  }
}

// MARK: - Relecture de la PR #61

@MainActor
private final class Counter {
  var value = 0
}

@Suite(.serialized) @MainActor struct CheckNextReviewTests {
  private func items(_ harness: Harness) throws -> (milk: UUID, bread: UUID) {
    let all = try harness.lists.items(listId: harness.listId)
    return (
      try #require(all.first { $0.label == "lait" }?.id), try #require(all.first { $0.label == "pain" }?.id)
    )
  }

  private func actions(
    _ harness: Harness, activity: any ShoppingActivityControlling, session: ShoppingSession? = nil,
    scheduled: Counter = Counter()
  ) -> ShoppingActivityActions {
    ShoppingActivityActions(
      lists: harness.lists, visits: harness.visits, stores: harness.stores, categories: harness.categories,
      analyzer: harness.analyzer, activity: activity, session: { session }, now: { [harness] in harness.date },
      scheduleSync: { scheduled.value += 1 })
  }

  @Test func aRekeyedVisitGetsANewActivityWithTheNewVisit() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    let old = try #require(session.visitId)
    let renamed = UUID()

    session.apply(IdentifierRemap(identifiers: [old: renamed]))
    guard case .start(let attributes, _)? = activity.calls.last else {
      Issue.record("pas de nouvelle activité après la reprise de compte")
      return
    }
    #expect(attributes.visitId == renamed)
    #expect(activity.calls.count == 2)
    #expect(activity.rekeys == [old: renamed])
  }

  @Test func aTapWhileTheShoppingModePreparesIsShownFromTheBase() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("pain")
    let (milk, bread) = try items(harness)
    let visit = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    let visitId = visit.id
    let activity = RecordingActivity()
    let gateway = SnapshotGateway(gated: true)
    let session = harness.session(gateway: gateway, preloadTimeout: .seconds(30), activity: activity)
    let resuming = Task { await session.resume(visit: visit) }
    while session.visitId == nil { await Task.yield() }
    #expect(!session.isActivityReady)
    activity.restored[visitId] = ActivityState(remaining: 2, total: 2, pendingItemIds: [milk, bread])

    await actions(harness, activity: activity, session: session).checkNext(visitId: visitId, itemId: milk)
    #expect(try harness.visits.checks(visitId: visitId).map(\.itemId) == [milk])
    #expect(activity.states.last?.nextItemId == bread)

    await gateway.openGate()
    await resuming.value
  }

  @Test func aFreshVisitIsResumedAtLaunch() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let environment = try AppEnvironment(
      container: harness.container,
      shoppingActivity: ActivityKitShoppingActivity(backend: FakeBackend(), dismissals: MemoryDismissals()))
    let visit = try harness.visitElsewhere(checkedAt: t0.addingTimeInterval(60))

    let session = await environment.resumeShopping(now: t0.addingTimeInterval(120))
    #expect(session?.visitId == visit)
    #expect(try harness.visits.visit(id: visit)?.endedAt == nil)
  }

  @Test func twoConcurrentTapsMakeOneCheck() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("pain")
    let (milk, bread) = try items(harness)
    let visit = try harness.visits.startVisit(
      storeId: harness.storeId, listId: harness.listId, listWasSorted: false, at: t0)
    let visitId = visit.id
    let attributes = ShoppingActivityAttributes(visitId: visitId, listName: "Semaine", storeName: nil)
    let shown = ActivityState(remaining: 2, total: 2, pendingItemIds: [milk, bread])
    let backend = FakeBackend([
      ActivityInfo(id: "a", visitId: visitId, isActive: true, attributes: attributes, state: shown)
    ])
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    let scheduled = Counter()
    let checkNext = actions(harness, activity: controller, scheduled: scheduled)

    async let first: Void = checkNext.checkNext(visitId: visitId, itemId: milk)
    async let second: Void = checkNext.checkNext(visitId: visitId, itemId: milk)
    _ = await (first, second)
    #expect(try harness.visits.checks(visitId: visitId).map(\.itemId) == [milk])
    #expect(await controller.restore(visitId: visitId)?.nextItemId == bread)
    #expect(scheduled.value == 1)
  }

  @Test func aTapFromTheActivityKeepsTheScreenUndoValid() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("pain")
    let (milk, bread) = try items(harness)
    let activity = RecordingActivity()
    let session = harness.session(activity: activity)
    await session.start()
    let visitId = try #require(session.visitId)
    session.toggle(try row(session, "lait"))
    #expect(session.undo?.itemId == milk)
    activity.restored[visitId] = activity.states.last

    await actions(harness, activity: activity, session: session).checkNext(visitId: visitId, itemId: bread)
    #expect(session.undo?.itemId == milk)

    session.performUndo()
    #expect(try harness.item(milk).checkedAt == nil)
    #expect(try harness.item(bread).checkedAt != nil)
    #expect(try harness.visits.checks(visitId: visitId).map(\.itemId) == [bread])
    #expect(session.errorMessage == nil)
  }
}

/// #54 : le LRU des instantanés compte l'usage, pas seulement le téléchargement.
@Suite(.serialized) @MainActor struct GraphSnapshotUsageTests {
  @Test func aStoreUsedForShoppingKeepsItsSnapshotAgainstStoresJustPassingBy() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.saveSnapshot()
    for offset in 1..<SwiftDataGraphRepository.maxSnapshots {
      try harness.graphs.saveSnapshot(
        storeId: UUID(), snapshotVersion: 1, paramsVersion: 1, confidenceQ: 0, payload: Data(),
        at: t0.addingTimeInterval(Double(offset)))
    }

    // Courses hors ligne (ou version inchangée au serveur) : rien n'est retéléchargé.
    harness.date = t0.addingTimeInterval(60)
    let session = harness.session()
    await session.start()
    #expect(session.knowledge != .unknown)

    // Un magasin de passage arrive : c'est le moins récemment utilisé qui part, pas celui des courses.
    try harness.graphs.saveSnapshot(
      storeId: UUID(), snapshotVersion: 1, paramsVersion: 1, confidenceQ: 0, payload: Data(),
      at: t0.addingTimeInterval(120))
    #expect(try harness.graphs.snapshot(storeId: harness.storeId) != nil)
    #expect(try harness.context.fetchCount(FetchDescriptor<GraphSnapshot>()) == SwiftDataGraphRepository.maxSnapshots)
  }

  @Test func touchingNeverMovesASnapshotBackInTime() throws {
    let harness = try Harness()
    try harness.saveSnapshot()
    try harness.graphs.touch(storeId: harness.storeId, at: t0.addingTimeInterval(-60))
    #expect(try harness.graphs.snapshot(storeId: harness.storeId)?.fetchedAt == t0)
    try harness.graphs.touch(storeId: harness.storeId, at: t0.addingTimeInterval(60))
    #expect(try harness.graphs.snapshot(storeId: harness.storeId)?.fetchedAt == t0.addingTimeInterval(60))
  }
}

/// #54 : « Terminer » touché pendant la préparation du mode courses.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct ShoppingPreparationTests {
  @Test func finishingBeforeThePreparationEndsDoesNothing() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let gateway = SnapshotGateway(gated: true)
    let session = harness.session(gateway: gateway, preloadTimeout: .seconds(30))
    let starting = Task { await session.start() }
    while await gateway.knownVersions.isEmpty { await Task.yield() }
    #expect(!session.isPrepared)

    session.finish(keepRemaining: true)
    #expect(session.summary == nil)

    await gateway.openGate()
    await starting.value
    // La visite ouverte par la préparation reste suivie : rien n'a été fermé avant elle.
    let visitId = try #require(session.visitId)
    #expect(try harness.visits.visit(id: visitId)?.endedAt == nil)
    #expect(session.isPrepared)

    session.finish(keepRemaining: true)
    #expect(session.summary != nil)
    #expect(try harness.visits.openVisit() == nil)
  }

  @Test func aSecondFinishDoesNotRewriteTheSummary() async throws {
    let harness = try Harness()
    try harness.add("lait")
    let session = harness.session()
    await session.start()
    session.finish(keepRemaining: true)
    let summary = session.summary
    harness.date = t0.addingTimeInterval(600)
    session.finish(keepRemaining: false)
    #expect(session.summary == summary)
    #expect(try harness.lists.items(listId: harness.listId).count == 1)
  }

  /// #54 : « Annuler » touché pendant une reprise de compte. Sur iOS, la réidentification et sa correspondance
  /// arrivent dans le même tour du MainActor : aucun toucher ne s'intercale, et l'annulation suit les nouveaux
  /// identifiants. La coche retenue ne part pas.
  @Test func undoRightAfterARekeyKeepsTheHeldCheckHome() async throws {
    let harness = try Harness()
    try harness.add("lait")
    try harness.add("pain")
    let session = harness.session()
    await session.start()
    session.toggle(try row(session, "lait"))

    // Ce que fait l'observateur de la notification, sans la diffuser aux sessions encore vivantes d'autres tests.
    let remap = try AccountRekey.run(in: harness.context, now: t0)
    session.apply(remap)
    session.performUndo()

    #expect(session.errorMessage == nil)
    #expect(try harness.outbox(.insertChecks).isEmpty)
    #expect(try harness.outbox(.createVisit).isEmpty)
    #expect(try harness.lists.items(listId: remap[harness.listId]).allSatisfy { $0.checkedAt == nil })
  }
}

/// Suppression du compte (#68) : la Live Activity disparaît en entier, et plus rien n'est publié avant la reprise.
@Suite @MainActor struct ActivityDeletionTests {
  private let visitA = UUID()
  private let state = ActivityState(remaining: 2, total: 3)

  private func attributes(_ visit: UUID?) -> ShoppingActivityAttributes {
    ShoppingActivityAttributes(visitId: visit, listName: "Semaine", storeName: "Leclerc Auch")
  }

  /// `endAll` laisse « Courses terminées » jusqu'à son retrait prévu ; `endEverything` le retire tout de suite : le nom
  /// de la liste et du magasin ne reste pas sur l'écran verrouillé.
  @Test func endEverythingEndsFinishedActivitiesImmediately() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    controller.end(state: ActivityState(remaining: 0, total: 3, isFinished: true))
    await controller.waitUntilIdle()
    controller.endAll(except: nil)
    await controller.waitUntilIdle()
    #expect(await backend.current().map(\.isActive) == [false])

    controller.endEverything()
    await controller.waitUntilIdle()

    #expect(await backend.current().isEmpty)
    #expect(await backend.calls.last == .end("new", immediate: true))
  }

  @Test func nothingIsPublishedDuringTheDeletionThenPublishingResumes() async {
    let backend = FakeBackend()
    let controller = ActivityKitShoppingActivity(backend: backend, dismissals: MemoryDismissals())
    controller.start(attributes: attributes(visitA), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    controller.endEverything()
    await controller.waitUntilIdle()
    let callsAfterEnd = await backend.calls

    // État en mémoire oublié : ni mise à jour, ni nouvel essai, ni reprise, ni démarrage.
    controller.update(state: ActivityState(remaining: 1, total: 3), lastActivity: t0)
    controller.retryIfNeeded()
    controller.start(attributes: attributes(UUID()), state: state, lastActivity: t0)
    #expect(await controller.restore(visitId: visitA) == nil)
    await controller.waitUntilIdle()
    #expect(await backend.calls == callsAfterEnd)
    #expect(controller.isHalted)

    controller.resumePublishing()
    let visitB = UUID()
    controller.start(attributes: attributes(visitB), state: state, lastActivity: t0)
    await controller.waitUntilIdle()
    #expect(await backend.calls.last == .request(visitB))
  }
}
