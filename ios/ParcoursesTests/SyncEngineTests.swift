import Foundation
import SwiftData
import Testing

@testable import Parcourses

private nonisolated let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Horloge modifiable depuis les tests.
private nonisolated final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = t0.addingTimeInterval(3600)
  var now: Date {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
  func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private nonisolated final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool
  init(_ value: Bool) { self.value = value }
  var isOn: Bool {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

private nonisolated final class MemoryCursors: SyncCursors, @unchecked Sendable {
  var accountId: UUID?
  var lists: Date?
  var items: Date?
  var catalog: Date?
}

/// Doublure : journal des appels et erreurs programmées par nom d'appel.
private actor ScriptedGateway: RemoteGateway {
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse { .none }
  var calls: [String] = []
  var failures: [String: [RemoteError]] = [:]
  var permanent: [String: RemoteError] = [:]
  var access: VisitAccess = .closed
  var account = UUID()
  var afterSaveList: (@Sendable () async -> Void)?
  var losesCheckResponses = false
  var visits: [VisitInsert] = []
  var checkBatches: [[CheckUpload]] = []
  var savedLists: [ListUpsert] = []
  var savedItems: [ListItemUpsert] = []
  var listRows: [ListRow] = []
  var itemRows: [ListItemRow] = []
  var categories: [CategoryRow] = []
  var products: [RemoteProduct] = []
  var listCursors: [Date?] = []
  var failingCheck: UUID?
  var failingList: UUID?
  var failingCheckError: RemoteError = .constraint(code: "23514")

  func fail(_ name: String, with errors: [RemoteError]) { failures[name] = errors }
  func failAlways(_ name: String, with error: RemoteError?) { permanent[name] = error }
  func setAccess(_ value: VisitAccess) { access = value }
  func setPull(lists: [ListRow] = [], items: [ListItemRow] = []) {
    listRows = lists
    itemRows = items
  }
  func setCatalog(categories: [CategoryRow], products: [RemoteProduct]) {
    self.categories = categories
    self.products = products
  }
  func setFailingCheck(_ id: UUID, error: RemoteError) {
    failingCheck = id
    failingCheckError = error
  }
  func setFailingList(_ id: UUID) { failingList = id }
  func clearCalls() { calls = [] }

  private func record(_ name: String) throws {
    calls.append(name)
    if let error = permanent[name] { throw error }
    if var queued = failures[name], !queued.isEmpty {
      let error = queued.removeFirst()
      failures[name] = queued
      throw error
    }
  }

  func ensureSession(captchaToken: String?) async throws -> UUID {
    try record("ensureSession")
    return account
  }
  func currentAccountId() async throws -> UUID { account }
  func verifySession() async throws { try record("verifySession") }
  func setAccount(_ id: UUID) { account = id }
  func setAfterSaveList(_ hook: (@Sendable () async -> Void)?) { afterSaveList = hook }
  func setLosesCheckResponses(_ value: Bool) { losesCheckResponses = value }
  func saveList(_ list: ListUpsert) async throws {
    try record("saveList")
    if list.id == failingList { throw RemoteError.dependencyMissing(code: "23503") }
    savedLists.append(list)
    if let hook = afterSaveList {
      afterSaveList = nil
      await hook()
    }
  }
  func deleteList(id: UUID) async throws { try record("deleteList") }
  func saveItem(_ item: ListItemUpsert) async throws {
    try record("saveItem")
    savedItems.append(item)
  }
  func deleteItem(id: UUID) async throws { try record("deleteItem") }
  func createVisit(_ visit: VisitInsert) async throws {
    try record("createVisit")
    visits.append(visit)
  }
  func insertChecks(_ checks: [CheckUpload]) async throws {
    try record("insertChecks")
    if let failingCheck, checks.contains(where: { $0.id == failingCheck }) { throw failingCheckError }
    checkBatches.append(checks)
    if losesCheckResponses {
      losesCheckResponses = false
      throw RemoteError.network
    }
  }
  func closeVisit(id: UUID, endedAt: Date) async throws { try record("closeVisit") }
  func visitAccess(id: UUID) async throws -> VisitAccess {
    try record("visitAccess")
    return access
  }
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] {
    try record("fetchLists")
    listCursors.append(updatedAfter)
    return listRows
  }
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] {
    try record("fetchItems")
    return itemRows
  }
  func fetchCategories() async throws -> [CategoryRow] {
    try record("fetchCategories")
    return categories
  }
  func fetchProducts() async throws -> [RemoteProduct] {
    try record("fetchProducts")
    return products
  }
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] { [] }
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow] { [] }
}

private nonisolated final class TaskHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Task<Void, Never>?
  var task: Task<Void, Never>? {
    get { lock.withLock { value } }
    set { lock.withLock { value = newValue } }
  }
}

@MainActor
private final class Harness {
  let container: ModelContainer
  let gateway = ScriptedGateway()
  let clock = Clock()
  let online = Flag(true)
  let cursors = MemoryCursors()
  let lists: SwiftDataListRepository
  let visits: SwiftDataVisitRepository
  let categories: SwiftDataCategoryRepository
  let engine: SyncEngine
  var context: ModelContext { container.mainContext }

  init() throws {
    container = try PersistenceStack.makeContainer(storage: .inMemory)
    lists = SwiftDataListRepository(context: container.mainContext)
    visits = SwiftDataVisitRepository(context: container.mainContext)
    categories = SwiftDataCategoryRepository(context: container.mainContext)
    let (clock, online) = (clock, online)
    engine = SyncEngine(
      gateway: gateway, container: container, cursors: cursors,
      classify: { PulledItemClassification(normalizedName: $0.lowercased(), categoryId: "other") },
      dependencies: SyncEngine.Dependencies(
        now: { clock.now }, jitter: { 1 }, isOnline: { online.isOn },
        // Pas de réveil autonome : les tests rythment les passes.
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
  }

  func entries() throws -> [OutboxEntry] {
    try context.fetch(FetchDescriptor<OutboxEntry>(sortBy: [SortDescriptor(\.sequence)]))
  }

  func kinds() throws -> [OutboxKind?] { try entries().map(\.kind) }

  /// Liste, article, visite avec une coche, close.
  @discardableResult
  func seedVisit(checks: Int = 1) throws -> (list: ShoppingList, visit: Visit) {
    let list = try lists.createList(name: "Courses", at: t0)
    let item = try lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    let visit = try visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: t0)
    for index in 0..<checks {
      try visits.addCheck(
        visitId: visit.id, itemId: item.id, subject: .category("dairy"),
        checkedAt: t0.addingTimeInterval(Double(index)))
    }
    return (list, visit)
  }

  func skipBackoff() async {
    clock.advance(SyncRetryPolicy.maximumDelay * 2)
  }
}

@MainActor
@Suite struct OutboxWritesTests {
  @Test func everyListWriteEntersTheQueueWithIt() throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    #expect(try harness.kinds() == [.upsertList, .upsertItem])

    // Fusion : la dernière valeur gagne.
    try harness.lists.renameList(id: list.id, name: "B", at: t0)
    try harness.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    #expect(try harness.kinds() == [.upsertList, .upsertItem])
    let upsert = try OutboxCoding.decode(ListUpsert.self, from: try #require(harness.entries().first).payload)
    #expect(upsert.name == "B")

    // Champ local : rien en file.
    let before = try harness.entries().count
    try harness.lists.setNotFound(itemId: item.id, notFoundAt: t0, at: t0)
    #expect(try harness.entries().count == before)

    try harness.lists.deleteItem(id: item.id)
    #expect(try harness.kinds() == [.upsertList, .deleteItem])
    try harness.lists.deleteList(id: list.id, at: t0)
    #expect(try harness.kinds() == [.deleteList])
  }

  @Test func aVisitWithoutCheckIsNeverQueued() throws {
    let harness = try Harness()
    let visit = try harness.visits.startVisit(storeId: UUID(), listId: UUID(), listWasSorted: false, at: t0)
    #expect(try harness.entries().isEmpty)
    #expect(try harness.visits.closeVisit(id: visit.id, at: t0) == false)
    #expect(try harness.entries().isEmpty)
  }

  @Test func theCreationIsQueuedOnlyAtTheFirstCheck() throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit(checks: 2)
    #expect(try harness.kinds() == [.upsertList, .upsertItem, .createVisit, .insertChecks, .insertChecks])
    try harness.visits.closeVisit(id: visit.id, at: t0)
    #expect(try harness.kinds().last == .closeVisit)
  }
}

@MainActor
@Suite(.serialized) struct SyncEngineSendTests {
  @Test func offlineThenBackDeliversEverythingInOrder() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit(checks: 3)
    try harness.visits.closeVisit(id: visit.id, at: t0.addingTimeInterval(60))
    let count = try harness.entries().count

    // Le système annonce l'absence de réseau : aucun appel.
    harness.online.isOn = false
    await harness.engine.drain()
    #expect(await harness.gateway.calls.isEmpty)

    // Le système se trompe : l'échec ne consomme aucun essai et ne perd rien.
    harness.online.isOn = true
    await harness.gateway.failAlways("saveList", with: .network)
    await harness.engine.drain()
    #expect(try harness.entries().count == count)
    #expect(try harness.entries().allSatisfy { $0.attempts == 0 && $0.syncState == .pending })
    #expect(await harness.gateway.calls == ["saveList"])

    // Délai global : un nouveau déclenchement n'insiste pas.
    await harness.engine.drain()
    #expect(await harness.gateway.calls == ["saveList"])

    // Retour du réseau.
    await harness.gateway.failAlways("saveList", with: nil)
    await harness.gateway.clearCalls()
    await harness.engine.drain(pull: true)
    #expect(
      await harness.gateway.calls.prefix(5).elementsEqual([
        "saveList", "saveItem", "createVisit", "insertChecks", "closeVisit",
      ]))
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.checkBatches.map(\.count) == [3])
    #expect(try harness.visits.visit(id: visit.id)?.syncState == .synced)
    #expect(try harness.visits.visit(id: visit.id)?.endSyncState == .synced)
    #expect(try harness.visits.checks(visitId: visit.id).allSatisfy { $0.syncState == .synced })
    #expect(try harness.lists.lists().allSatisfy { $0.syncState == .synced })
  }

  @Test func replayAfterAnInterruptedRunStaysIdempotent() async throws {
    let harness = try Harness()
    try harness.seedVisit()
    await harness.gateway.fail("insertChecks", with: [.network])
    await harness.engine.drain()
    #expect(try harness.kinds() == [.insertChecks])
    await harness.skipBackoff()
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.visits.count == 1)
  }

  @Test func checksAreBatchedByTwoHundred() async throws {
    let harness = try Harness()
    try harness.seedVisit(checks: 205)
    await harness.engine.drain()
    #expect(await harness.gateway.checkBatches.map(\.count) == [200, 5])
  }

  @Test func aClosureNeverOvertakesItsChecks() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit()
    try harness.visits.closeVisit(id: visit.id, at: t0.addingTimeInterval(1))
    await harness.gateway.failAlways("insertChecks", with: .dependencyMissing(code: "23503"))
    await harness.engine.drain()
    #expect(await !harness.gateway.calls.contains("closeVisit"))
    #expect(try harness.kinds() == [.insertChecks, .closeVisit])
  }

  @Test func aMissingDependencyIsCappedThenFails() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let other = try harness.lists.createList(name: "B", at: t0)
    await harness.gateway.setFailingList(list.id)
    for _ in 0..<SyncRetryPolicy.maxDependencyAttempts {
      await harness.engine.drain()
      await harness.skipBackoff()
    }
    let failed = try harness.entries().filter { $0.syncState == .failed }
    #expect(failed.count == 1)
    #expect(failed.first?.entityId == list.id)
    #expect(try harness.lists.list(id: list.id)?.syncState == .failed)
    // L'autre liste n'a pas été bloquée.
    #expect(try harness.lists.list(id: other.id)?.syncState == .synced)
  }

  @Test func anUnknownCategoryNeverFails() async throws {
    let harness = try Harness()
    try harness.seedVisit()
    await harness.gateway.failAlways("insertChecks", with: .unknownCategory("dairy"))
    for _ in 0..<60 {
      await harness.engine.drain()
      harness.clock.advance(SyncRetryPolicy.unknownCategoryDelay * 2)
    }
    #expect(try harness.entries().first?.syncState == .pending)
    #expect(await harness.gateway.visits.count == 1)
  }

  @Test func aRefusedBatchIsSplitToIsolateTheBadCheck() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit(checks: 3)
    let bad = try harness.visits.checks(visitId: visit.id)[1]
    await harness.gateway.setFailingCheck(bad.id, error: .constraint(code: "23514"))
    await harness.engine.drain()
    #expect(await harness.gateway.checkBatches.map(\.count) == [1, 1])
    #expect(try harness.visits.checks(visitId: visit.id)[1].syncState == .failed)
    #expect(try harness.entries().count == 1)
  }

  @Test func aDeletedListSendsTheVisitAgainWithoutList() async throws {
    let harness = try Harness()
    try harness.seedVisit()
    await harness.gateway.fail("createVisit", with: [.forbidden])
    await harness.engine.drain()
    let visits = await harness.gateway.visits
    #expect(visits.count == 1)
    #expect(visits.first?.listId == nil)
    #expect(try harness.entries().isEmpty)
  }

  @Test func aVisitRefusedWithoutListFailsWithItsChecks() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit()
    await harness.gateway.failAlways("createVisit", with: .forbidden)
    await harness.engine.drain()
    #expect(try harness.visits.visit(id: visit.id)?.syncState == .failed)
    #expect(await harness.gateway.calls.contains("verifySession"))
    #expect(await !harness.gateway.calls.contains("insertChecks"))
    #expect(try harness.entries().filter { $0.syncState == .pending }.isEmpty)
  }

  @Test func aLateCheckInOurClosedVisitCountsAsReceived() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit()
    await harness.gateway.fail("insertChecks", with: [.forbidden])
    await harness.gateway.setAccess(.closed)
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    #expect(try harness.visits.checks(visitId: visit.id).first?.syncState == .synced)
    #expect(await harness.gateway.checkBatches.isEmpty)
  }

  @Test func aCheckInAnotherAccountsVisitStaysLocalWithoutBlockingTheQueue() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit()
    await harness.gateway.failAlways("insertChecks", with: .forbidden)
    await harness.gateway.setAccess(.notVisible)
    await harness.engine.drain()
    #expect(try harness.visits.checks(visitId: visit.id).allSatisfy { $0.syncState == .failed })
    #expect(try harness.entries().allSatisfy { $0.syncState == .failed })
    #expect(try harness.visits.visit(id: visit.id) != nil)
    let list = try harness.lists.createList(name: "Suite", at: t0)
    let id = list.id
    await harness.engine.drain()
    #expect(try harness.lists.list(id: id)?.syncState == .synced)
  }

  /// Revue #40 : le découpage du lot ne doit jamais tourner en boucle sur un `42501` en visite ouverte.
  @Test func aRefusalInAnOpenVisitWithSeveralChecksDoesNotSpin() async throws {
    let harness = try Harness()
    try harness.seedVisit(checks: 3)
    await harness.gateway.failAlways("insertChecks", with: .forbidden)
    await harness.gateway.setAccess(.open)
    let engine = harness.engine
    let drain = Task { await engine.drain() }
    try await Task.sleep(for: .seconds(2))
    drain.cancel()
    await drain.value
    #expect(await harness.gateway.calls.filter { $0 == "insertChecks" }.count == 1)
    #expect(try harness.entries().allSatisfy { $0.syncState == .pending && $0.attempts <= 1 })
  }

  @Test func aRefusalInAnOpenVisitIsCapped() async throws {
    let harness = try Harness()
    try harness.seedVisit(checks: 3)
    await harness.gateway.failAlways("insertChecks", with: .forbidden)
    await harness.gateway.setAccess(.open)
    for _ in 0..<SyncRetryPolicy.maxDependencyAttempts {
      await harness.engine.drain()
      await harness.skipBackoff()
    }
    #expect(try harness.entries().allSatisfy { $0.syncState == .failed })
  }

  @Test func aLostSessionNeverProducesAFailedEntry() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit()
    await harness.gateway.failAlways("createVisit", with: .forbidden)
    await harness.gateway.failAlways("verifySession", with: .unauthorized)
    await harness.engine.drain()
    #expect(await harness.engine.pause == .sessionRequired)
    #expect(try harness.entries().allSatisfy { $0.syncState == .pending })
    #expect(try harness.visits.visit(id: visit.id)?.syncState == .pending)
  }

  @Test func aSessionLostOnAForbiddenCheckPausesToo() async throws {
    let harness = try Harness()
    try harness.seedVisit()
    await harness.gateway.fail("insertChecks", with: [.forbidden])
    await harness.gateway.setAccess(.notVisible)
    await harness.gateway.failAlways("verifySession", with: .unauthorized)
    await harness.engine.drain()
    #expect(await harness.engine.pause == .sessionRequired)
    #expect(try harness.entries().allSatisfy { $0.syncState == .pending })
  }

  @Test func anUncodedClientErrorIsCapped() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let id = list.id
    await harness.gateway.failAlways("saveList", with: .server(code: "404"))
    for _ in 0..<SyncRetryPolicy.maxDependencyAttempts {
      await harness.engine.drain()
      await harness.skipBackoff()
    }
    #expect(try harness.lists.list(id: id)?.syncState == .failed)
  }

  /// Les coches ne s'attendent pas : une ligne en attente ne retient que la clôture.
  @Test func aPostponedCheckHoldsOnlyTheClosure() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit(checks: 3)
    try harness.visits.closeVisit(id: visit.id, at: t0.addingTimeInterval(10))
    let checks = try harness.visits.checks(visitId: visit.id)
    await harness.gateway.setFailingCheck(checks[0].id, error: .dependencyMissing(code: "23503"))
    await harness.engine.drain()
    #expect(await harness.gateway.checkBatches.flatMap { $0 }.count == 2)
    #expect(await !harness.gateway.calls.contains("closeVisit"))
    #expect(try harness.kinds() == [.insertChecks, .closeVisit])
  }

  /// Envoyé, reçu par le serveur, puis appli tuée avant `complete` : un nouveau moteur renvoie les mêmes lignes.
  @Test func sentThenKilledBeforeCompleteResendsTheSameIds() async throws {
    let harness = try Harness()
    let (_, visit) = try harness.seedVisit(checks: 2)
    await harness.gateway.setLosesCheckResponses(true)
    await harness.engine.drain()
    #expect(try harness.kinds() == [.insertChecks, .insertChecks])

    let clock = harness.clock
    let restarted = SyncEngine(
      gateway: harness.gateway, container: harness.container, cursors: harness.cursors,
      classify: { PulledItemClassification(normalizedName: $0, categoryId: "other") },
      dependencies: SyncEngine.Dependencies(
        now: { clock.now }, jitter: { 1 }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    await restarted.drain()
    #expect(try harness.entries().isEmpty)
    let batches = await harness.gateway.checkBatches
    #expect(batches.count == 2)
    #expect(batches[0].map(\.id) == batches[1].map(\.id))
    #expect(try harness.visits.checks(visitId: visit.id).allSatisfy { $0.syncState == .synced })
  }

  @Test func anEntryReplacedDuringTheSendKeepsTheNewValue() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "Avant", at: t0)
    let id = list.id
    let repository = harness.lists
    let renamed = Flag(false)
    await harness.gateway.setAfterSaveList {
      await MainActor.run {
        try? repository.renameList(id: id, name: "Après", at: t0)
        renamed.isOn = true
      }
    }
    await harness.engine.drain()
    #expect(renamed.isOn)
    #expect(try harness.lists.list(id: id)?.syncState != .failed)
    await harness.skipBackoff()
    await harness.engine.drain()
    #expect(await harness.gateway.savedLists.map(\.name) == ["Avant", "Après"])
    #expect(try harness.entries().isEmpty)
    #expect(try harness.lists.list(id: id)?.syncState == .synced)
  }

  @Test func aKickDuringCancellationIsNotLost() async throws {
    let harness = try Harness()
    let first = try harness.lists.createList(name: "A", at: t0)
    _ = first
    try harness.lists.createList(name: "B", at: t0)
    let engine = harness.engine
    let holder = TaskHolder()
    await harness.gateway.setAfterSaveList {
      holder.task?.cancel()
      await engine.kick()
    }
    let drain = Task { await engine.drain() }
    holder.task = drain
    await drain.value
    for _ in 0..<40 where try harness.entries().isEmpty == false {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(try harness.entries().isEmpty)
  }

  @Test func theStoreDoesNotRunOnTheMainThread() async throws {
    let harness = try Harness()
    #expect(await harness.engine.storeIsOnMainThread() == false)
  }

  @Test func aStoppedEngineSendsNothingUntilRestarted() async throws {
    let harness = try Harness()
    try harness.lists.createList(name: "A", at: t0)
    await harness.engine.stopAndWait()
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.isEmpty)
    await harness.engine.restart()
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
  }

  @Test func aDeletionFinishesLocallyOnceAcknowledged() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let id = list.id
    try harness.lists.addItem(
      listId: id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    try harness.lists.deleteList(id: id, at: t0)
    await harness.engine.drain()
    #expect(await harness.gateway.calls.first == "deleteList")
    #expect(try harness.context.fetchCount(FetchDescriptor<ShoppingList>()) == 0)
    #expect(try harness.context.fetchCount(FetchDescriptor<ListItem>()) == 0)
  }
}

@MainActor
@Suite(.serialized) struct SyncPauseTests {
  @Test func aChangedAccountPausesWithoutSendingNorDeleting() async throws {
    let harness = try Harness()
    try harness.lists.createList(name: "A", at: t0)
    let before = try harness.entries().count
    await harness.gateway.failAlways("saveList", with: .accountChanged)
    await harness.engine.drain()
    #expect(await harness.engine.pause == .accountChanged)
    #expect(try harness.entries().count == before)
    #expect(try harness.entries().allSatisfy { $0.attempts == 0 && $0.syncState == .pending })

    // Ni un nouveau déclenchement, ni une passe forcée, ne relancent l'envoi.
    await harness.gateway.clearCalls()
    await harness.engine.drain()
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.isEmpty)

    await harness.gateway.failAlways("saveList", with: nil)
    await harness.engine.resume()
    await harness.engine.drain()
    #expect(await harness.engine.pause == nil)
    #expect(try harness.entries().isEmpty)
  }

  @Test func aLostSessionPausesThenResumesWhenItReturns() async throws {
    let harness = try Harness()
    try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.failAlways("saveList", with: .unauthorized)
    await harness.engine.drain()
    #expect(await harness.engine.pause == .sessionRequired)
    #expect(try harness.entries().first?.attempts == 0)

    // Une nouvelle écriture n'insiste pas.
    await harness.gateway.clearCalls()
    await harness.engine.drain()
    #expect(await harness.gateway.calls.isEmpty)

    // Passe forcée (premier plan) : pas de session, on reste en pause, sans toucher à la file.
    await harness.gateway.failAlways("ensureSession", with: .unauthorized)
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls == ["ensureSession"])
    #expect(await harness.engine.pause == .sessionRequired)

    await harness.gateway.failAlways("ensureSession", with: nil)
    await harness.gateway.failAlways("saveList", with: nil)
    await harness.engine.drain(pull: true)
    #expect(await harness.engine.pause == nil)
    #expect(try harness.entries().isEmpty)
  }

  @Test func aLockedKeychainIsNotALostSession() async throws {
    let harness = try Harness()
    try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.fail("saveList", with: [.keychainLocked])
    await harness.engine.drain()
    #expect(await harness.engine.pause == nil)
    #expect(try harness.entries().count == 1)
  }

  @Test func aPullDetectsTheLostSession() async throws {
    let harness = try Harness()
    await harness.gateway.failAlways("fetchLists", with: .unauthorized)
    await harness.engine.drain(pull: true)
    #expect(await harness.engine.pause == .sessionRequired)
    await harness.engine.resume()
    await harness.gateway.failAlways("fetchLists", with: .accountChanged)
    await harness.engine.drain(pull: true)
    #expect(await harness.engine.pause == .accountChanged)
  }

  @Test func changesAreStreamedToTheLoginScreen() async throws {
    let harness = try Harness()
    try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.failAlways("saveList", with: .unauthorized)
    await harness.engine.drain()
    var updates = harness.engine.pauseUpdates.makeAsyncIterator()
    #expect(await updates.next() == .some(.sessionRequired))
  }
}

private func listRow(_ id: UUID, name: String, updatedAt: Date) -> ListRow {
  ListRow(id: id, ownerId: UUID(), name: name, createdAt: t0, updatedAt: updatedAt)
}

private func itemRow(_ id: UUID, listId: UUID, label: String, updatedAt: Date) -> ListItemRow {
  ListItemRow(
    id: id, listId: listId, productId: nil, label: label, quantity: "2", checkedAt: nil, createdAt: t0,
    updatedAt: updatedAt)
}

@MainActor
@Suite(.serialized) struct SyncPullTests {
  @Test func newRowsAreCreatedAndTheCursorAdvances() async throws {
    let harness = try Harness()
    let listId = UUID()
    let later = t0.addingTimeInterval(100)
    await harness.gateway.setPull(
      lists: [listRow(listId, name: "Serveur", updatedAt: t0)],
      items: [itemRow(UUID(), listId: listId, label: "Beurre", updatedAt: later)])
    await harness.engine.drain(pull: true)
    #expect(try harness.lists.list(id: listId)?.name == "Serveur")
    let item = try #require(try harness.lists.items(listId: listId).first)
    #expect(item.normalizedName == "beurre")
    #expect(item.categoryId == "other")
    #expect(item.syncState == .synced)
    #expect(harness.cursors.lists == t0)
    #expect(harness.cursors.items == later)
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.listCursors == [nil, t0])
  }

  @Test func aPendingLocalWriteWinsOverTheServer() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "Local", at: t0)
    await harness.gateway.failAlways("saveList", with: .dependencyMissing(code: "23503"))
    await harness.gateway.setPull(lists: [listRow(list.id, name: "Serveur", updatedAt: t0.addingTimeInterval(500))])
    await harness.engine.drain(pull: true)
    #expect(try harness.lists.list(id: list.id)?.name == "Local")
  }

  /// Revue #40 : sans entrée en attente, la ligne serveur s'applique, sans comparer deux horloges.
  @Test func theServerRowAppliesWithoutPendingEntryWhateverTheClocks() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "Local", at: t0)
    let id = list.id
    await harness.engine.drain()
    await harness.gateway.setPull(lists: [listRow(id, name: "Autre appareil", updatedAt: t0.addingTimeInterval(-10))])
    await harness.engine.drain(pull: true)
    #expect(try harness.lists.list(id: id)?.name == "Autre appareil")
  }

  /// Revue #40 : un champ local ne doit ni toucher `updatedAt`, ni masquer une modification distante.
  @Test func notFoundDoesNotHideARemoteChange() async throws {
    let harness = try Harness()
    let (list, _) = try harness.seedVisit()
    let item = try #require(try harness.lists.items(listId: list.id).first)
    await harness.engine.drain()
    let before = item.updatedAt
    let id = item.id
    try harness.lists.setNotFound(itemId: id, notFoundAt: t0.addingTimeInterval(500), at: t0.addingTimeInterval(500))
    #expect(item.updatedAt == before)
    await harness.gateway.setPull(items: [
      itemRow(id, listId: list.id, label: "Lait", updatedAt: t0.addingTimeInterval(10))
    ])
    await harness.engine.drain(pull: true)
    #expect(try harness.lists.items(listId: list.id).first?.quantity == "2")
  }

  @Test func aPulledItemKeepsItsLocalFields() async throws {
    let harness = try Harness()
    let (list, _) = try harness.seedVisit()
    let item = try #require(try harness.lists.items(listId: list.id).first)
    try harness.lists.setNotFound(itemId: item.id, notFoundAt: t0, at: t0)
    await harness.engine.drain()
    await harness.gateway.setPull(items: [
      itemRow(item.id, listId: list.id, label: "Lait", updatedAt: t0.addingTimeInterval(10))
    ])
    await harness.engine.drain(pull: true)
    let pulled = try #require(try harness.lists.items(listId: list.id).first)
    #expect(pulled.quantity == "2")
    #expect(pulled.categoryId == "dairy")
    #expect(pulled.notFoundAt == t0)
  }

  @Test func catalogNeverDeletesACategoryAndRefreshesDaily() async throws {
    let harness = try Harness()
    try harness.categories.seedIfNeeded()
    let before = Set(try harness.categories.categories().map(\.id))
    let slug = try #require(before.first)
    let product = RemoteProduct(
      id: UUID(), name: "Lait", normalizedName: "lait", categorySlug: slug, offCode: nil, createdAt: t0)
    let unknown = RemoteProduct(
      id: UUID(), name: "X", normalizedName: "x", categorySlug: "inconnue", offCode: nil, createdAt: t0)
    await harness.gateway.setCatalog(
      categories: [CategoryRow(id: 7, slug: slug, name: "n", defaultRank: 1)], products: [product, unknown])
    await harness.engine.drain(pull: true)
    #expect(Set(try harness.categories.categories().map(\.id)) == before)
    #expect(try harness.categories.categories().first { $0.id == slug }?.remoteId == 7)
    let cached = try harness.context.fetch(FetchDescriptor<Product>())
    #expect(cached.first { $0.id == product.id }?.categoryId == slug)
    #expect(cached.first { $0.id == unknown.id }?.categoryId == nil)

    // Réponse vide : cache intact. Pas de nouvel appel dans la journée.
    await harness.gateway.setCatalog(categories: [], products: [])
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.filter { $0 == "fetchProducts" }.count == 1)
    harness.clock.advance(SyncRetryPolicy.catalogInterval)
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.filter { $0 == "fetchProducts" }.count == 2)
    #expect(Set(try harness.categories.categories().map(\.id)) == before)
    #expect(try harness.context.fetchCount(FetchDescriptor<Product>()) == 2)

    // Le produit disparu du catalogue quitte le cache.
    await harness.gateway.setCatalog(categories: [], products: [product])
    harness.clock.advance(SyncRetryPolicy.catalogInterval)
    await harness.engine.drain(pull: true)
    #expect(try harness.context.fetchCount(FetchDescriptor<Product>()) == 1)
  }

  @Test func aFailedPullKeepsTheCursorAndRetriesOncePerMinute() async throws {
    let harness = try Harness()
    await harness.gateway.fail("fetchItems", with: [.network])
    await harness.gateway.setPull(lists: [listRow(UUID(), name: "A", updatedAt: t0)])
    await harness.engine.drain(pull: true)
    #expect(harness.cursors.lists == nil)
    await harness.gateway.clearCalls()
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.calls.isEmpty)
    harness.clock.advance(SyncRetryPolicy.pullRetryInterval)
    await harness.engine.drain(pull: true)
    #expect(harness.cursors.lists == t0)
  }

  @Test func aFailedPullDoesNotBlockSending() async throws {
    let harness = try Harness()
    await harness.gateway.failAlways("fetchLists", with: .server(code: "503"))
    await harness.engine.drain(pull: true)
    let list = try harness.lists.createList(name: "A", at: t0)
    let id = list.id
    await harness.engine.drain()
    #expect(try harness.lists.list(id: id)?.syncState == .synced)
  }

  @Test func anItemWithoutParentHoldsTheCursor() async throws {
    let harness = try Harness()
    let listId = UUID()
    let itemId = UUID()
    let row = itemRow(itemId, listId: listId, label: "Beurre", updatedAt: t0)
    let later = itemRow(UUID(), listId: listId, label: "Lait", updatedAt: t0.addingTimeInterval(50))
    await harness.gateway.setPull(items: [row, later])
    await harness.engine.drain(pull: true)
    #expect(harness.cursors.items == t0)
    #expect(try harness.context.fetchCount(FetchDescriptor<ListItem>()) == 0)

    // Le parent arrive : les lignes sont relues.
    await harness.gateway.setPull(lists: [listRow(listId, name: "L", updatedAt: t0)], items: [row, later])
    await harness.engine.drain(pull: true)
    #expect(try harness.lists.items(listId: listId).count == 2)
    #expect(harness.cursors.items == t0.addingTimeInterval(50))
  }

  @Test func aPendingRowHoldsTheCursor() async throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "Local", at: t0)
    await harness.gateway.failAlways("saveList", with: .dependencyMissing(code: "23503"))
    await harness.gateway.setPull(lists: [
      listRow(list.id, name: "S", updatedAt: t0), listRow(UUID(), name: "Autre", updatedAt: t0.addingTimeInterval(50)),
    ])
    await harness.engine.drain(pull: true)
    #expect(harness.cursors.lists == t0)
  }

  @Test func cursorsOfAnotherAccountAreIgnored() async throws {
    let harness = try Harness()
    await harness.gateway.setPull(lists: [listRow(UUID(), name: "A", updatedAt: t0)])
    await harness.engine.drain(pull: true)
    await harness.gateway.setAccount(UUID())
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.listCursors == [nil, nil])
  }
}
