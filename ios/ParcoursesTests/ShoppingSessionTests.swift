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
    settleDelay: Duration = .milliseconds(1)
  ) -> ShoppingSession {
    ShoppingSession(
      listId: listId, storeId: withStore ? storeId : nil, lists: lists, visits: visits, stores: stores,
      categories: categories, analyzer: analyzer, cache: GraphSnapshotCache(graphs: graphs, gateway: gateway),
      // Capture forte : un tri encore en attente ne doit pas survivre au conteneur (fetch fatal après sa libération).
      now: { [self] in date }, settleDelay: settleDelay, highlightDelay: .milliseconds(1),
      preloadTimeout: preloadTimeout)
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
