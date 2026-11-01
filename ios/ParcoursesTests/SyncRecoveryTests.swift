import Foundation
import SwiftData
import Testing

@testable import Parcourses

private nonisolated let t0 = syncEpoch

@MainActor
private func all<Model: PersistentModel>(_ harness: SyncHarness, _ type: Model.Type = Model.self) throws -> [Model] {
  try harness.context.fetch(FetchDescriptor<Model>())
}

/// Perte de session : un nouveau compte anonyme ne voit plus rien, tout repart sous de nouveaux identifiants.
@MainActor
@Suite(.serialized) struct AccountRecoveryTests {
  /// Reçue et close : elle a pu nourrir le graphe partagé. La renvoyer l'y apprendrait une seconde fois.
  @Test func aReceivedClosedVisitStaysLocalUnderItsNewIdentifier() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 2)
    let oldVisit = seeded.visit.id
    try harness.visits.closeVisit(id: oldVisit, at: t0)
    await harness.engine.drain(pull: true)
    #expect(try harness.entries().isEmpty)
    let before = await harness.gateway.visits.count

    await harness.gateway.loseAccount()
    await harness.engine.drain(pull: true)

    let visit = try #require(try harness.fresh(Visit.self).first)
    let checks = try harness.fresh(Check.self)
    #expect(visit.id != oldVisit)
    #expect(visit.syncState == .synced && visit.endSyncState == .synced)
    #expect(try visit.listId == harness.fresh(ShoppingList.self).first?.id)
    #expect(checks.count == 2 && checks.allSatisfy { $0.visitId == visit.id && $0.syncState == .synced })
    #expect(await harness.gateway.visits.count == before)
    #expect(await harness.gateway.closures.count == 1)
    // Sa liste et ses articles appartiennent au compte : eux repartent.
    #expect(await harness.gateway.savedLists.last?.id == visit.listId)
    #expect(try harness.entries().isEmpty)
  }

  @Test func everythingNotReceivedIsResentUnderNewIdentifiers() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 2)
    let (oldList, oldVisit) = (seeded.list.id, seeded.visit.id)
    let oldItem = try #require(try all(harness, ListItem.self).first).id
    let oldChecks = Set(try all(harness, Check.self).map(\.id))
    await harness.engine.drain()
    await harness.gateway.setPull(lists: [
      ListRow(id: oldList, ownerId: UUID(), name: "Courses", createdAt: t0, updatedAt: t0)
    ])
    await harness.engine.drain(pull: true)
    await harness.gateway.setPull()
    #expect(harness.cursors.lists != nil)
    // Créée et cochée, mais jamais close côté serveur : pas apprise, donc à renvoyer en entier.
    try harness.visits.closeVisit(id: oldVisit, at: t0.addingTimeInterval(60))
    await harness.gateway.failAlways("closeVisit", with: .network)
    await harness.engine.drain()
    await harness.gateway.failAlways("closeVisit", with: nil)
    await harness.skipBackoff()
    #expect(try harness.kinds() == [.closeVisit])
    let previousAccount = harness.cursors.accountId

    await harness.gateway.loseAccount()
    await harness.gateway.clearCalls()
    await harness.engine.drain(pull: true)

    let list = try #require(try all(harness, ShoppingList.self).first)
    let item = try #require(try all(harness, ListItem.self).first)
    let visit = try #require(try all(harness, Visit.self).first)
    let checks = try all(harness, Check.self)
    #expect(try all(harness, ShoppingList.self).count == 1)
    #expect(checks.count == 2)
    #expect(list.id != oldList && item.id != oldItem && visit.id != oldVisit)
    #expect(oldChecks.isDisjoint(with: checks.map(\.id)))
    #expect(item.listId == list.id && visit.listId == list.id)
    #expect(checks.allSatisfy { $0.visitId == visit.id && $0.itemId == item.id })
    #expect(list.name == "Courses" && item.label == "Lait" && visit.endedAt == t0.addingTimeInterval(60))

    let gateway = harness.gateway
    #expect(await gateway.savedLists.last?.id == list.id)
    #expect(await gateway.savedItems.last?.id == item.id)
    #expect(await gateway.savedItems.last?.listId == list.id)
    #expect(await gateway.visits.last?.id == visit.id)
    #expect(await gateway.visits.last?.listId == list.id)
    #expect(Set(await gateway.checkBatches.last?.map(\.id) ?? []) == Set(checks.map(\.id)))
    let calls = await gateway.calls
    let order = ["saveList", "saveItem", "createVisit", "insertChecks", "closeVisit"].compactMap(calls.firstIndex(of:))
    #expect(order.count == 5 && order == order.sorted())

    #expect(try harness.entries().isEmpty)
    #expect(list.syncState == .synced && visit.syncState == .synced && visit.endSyncState == .synced)
    #expect(harness.cursors.accountId != previousAccount)
    #expect(await gateway.listCursors.last == .some(nil))
    #expect(await harness.engine.isWaitingForSession == false)
  }

  @Test func aSecondAccountChangeReplaysSafelyAfterAnInterruption() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit(checks: 1)
    await harness.engine.drain(pull: true)
    await harness.gateway.loseAccount()
    await harness.gateway.clearCalls()
    let listsBefore = await harness.gateway.savedLists.count

    // Arrêt entre l'écriture locale et l'accusé : rien ne part, rien ne se duplique, on rejoue.
    await harness.gateway.failAlways("acknowledgeAccount", with: .keychainLocked)
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.savedLists.count == listsBefore)
    #expect(try all(harness, ShoppingList.self).count == 1)
    #expect(try all(harness, Check.self).count == 1)
    let queued = try harness.kinds()
    #expect(queued == [.upsertList, .upsertItem, .createVisit, .insertChecks])
    let firstRun = try #require(try all(harness, ShoppingList.self).first).id

    // Relance du processus : nouveau moteur, mêmes données.
    await harness.gateway.failAlways("acknowledgeAccount", with: nil)
    let restarted = harness.makeEngine()
    await restarted.drain(pull: true)
    let list = try #require(try all(harness, ShoppingList.self).first)
    #expect(list.id != firstRun)
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.savedLists.count == listsBefore + 1)
    #expect(await harness.gateway.savedLists.last?.id == list.id)
  }

  @Test func anOpenVisitStaysOpenAndKeepsItsUndoDelay() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    let visit = try harness.visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: t0)
    let oldVisit = visit.id
    let held = harness.clock.now.addingTimeInterval(5)
    try harness.visits.addCheck(
      visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: harness.clock.now, sendAfter: 5)
    #expect(try harness.entries().last?.nextAttemptAt == held)

    await harness.gateway.setKnownAccount(UUID())
    await harness.engine.drain(pull: true)

    let open = try #require(try harness.visits.openVisit())
    #expect(open.id != oldVisit)
    #expect(await harness.gateway.closures.isEmpty)
    // La coche n'est pas partie : l'annulation reste possible, avec son identifiant neuf.
    #expect(await harness.gateway.checkBatches.isEmpty)
    let check = try #require(try all(harness, Check.self).first)
    #expect(check.visitId == open.id)
    #expect(try harness.visits.removeCheck(id: check.id))
    #expect(try harness.kinds().contains(.insertChecks) == false)
    #expect(try harness.kinds().contains(.createVisit) == false)
  }

  @Test func anOpenVisitWithoutCheckStaysLocal() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    try harness.visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: t0)
    await harness.gateway.setKnownAccount(UUID())
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.visits.isEmpty)
    #expect(try harness.visits.openVisit()?.listId == harness.lists.lists().first?.id)
  }

  @Test func aDeletedListIsNotResurrectedAndItsVisitSurvives() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 1)
    try harness.visits.closeVisit(id: seeded.visit.id, at: t0)
    try harness.lists.deleteList(id: seeded.list.id, at: t0)
    await harness.gateway.setKnownAccount(UUID())
    await harness.engine.drain(pull: true)

    #expect(try all(harness, ShoppingList.self).isEmpty)
    #expect(try all(harness, ListItem.self).isEmpty)
    #expect(await harness.gateway.savedLists.isEmpty)
    #expect(await harness.gateway.deletedLists.isEmpty)
    #expect(await harness.gateway.visits.first?.listId == nil)
    #expect(await harness.gateway.closures.count == 1)
    #expect(try harness.entries().isEmpty)
  }

  @Test func abandonedRowsGetAnotherChance() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit(checks: 1)
    await harness.gateway.failAlways("createVisit", with: .forbidden)
    await harness.gateway.setAccess(.notVisible)
    await harness.engine.drain()
    #expect(try all(harness, Visit.self).first?.syncState == .failed)

    await harness.gateway.failAlways("createVisit", with: nil)
    await harness.gateway.loseAccount()
    await harness.engine.drain(pull: true)
    #expect(try all(harness, Visit.self).first?.syncState == .synced)
    #expect(try all(harness, Check.self).first?.syncState == .synced)
    #expect(try harness.entries().isEmpty)
  }

  @Test func aLockedKeychainTouchesNothing() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let id = list.id
    await harness.gateway.failAlways("currentAccountId", with: .keychainLocked)
    await harness.engine.drain(pull: true)
    await harness.gateway.failAlways("ensureSession", with: .keychainLocked)
    await harness.engine.drain(pull: true)
    #expect(try all(harness, ShoppingList.self).first?.id == id)
    #expect(await harness.engine.isWaitingForSession == false)
    #expect(await harness.gateway.savedLists.isEmpty)

    // Même verrouillé au moment de la reprise : pas de réidentification sans compte établi.
    await harness.gateway.failAlways("currentAccountId", with: nil)
    await harness.gateway.setKnownAccount(UUID())
    await harness.gateway.failAlways("sessionAccountId", with: .keychainLocked)
    await harness.engine.drain(pull: true)
    #expect(try all(harness, ShoppingList.self).first?.id == id)
  }

  @Test func noSessionYetMeansWaitingNotRecovering() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let id = list.id
    await harness.gateway.failAlways("currentAccountId", with: .unauthorized)
    await harness.engine.drain()
    #expect(await harness.engine.isWaitingForSession)
    #expect(try all(harness, ShoppingList.self).first?.id == id)
  }

  /// Keychain vidé (restauration sur un autre iPhone) : la passerelle ne connaît plus l'ancien compte, le curseur si.
  @Test func anEmptiedKeychainIsDetectedThroughTheCursor() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let oldId = list.id
    await harness.engine.drain(pull: true)
    await harness.gateway.loseAccount()
    await harness.gateway.setKnownAccount(nil)
    await harness.engine.drain(pull: true)
    let current = try #require(try all(harness, ShoppingList.self).first).id
    #expect(current != oldId)
    #expect(await harness.gateway.savedLists.last?.id == current)
  }

  @Test func anOrphanItemProducesNoDoomedUpsert() async throws {
    let harness = try SyncHarness()
    harness.context.insert(
      ListItem(listId: UUID(), label: "Orphelin", normalizedName: "orphelin", categoryId: "other", position: 0))
    try harness.context.save()
    await harness.gateway.setKnownAccount(UUID())
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.savedItems.isEmpty)
    #expect(try harness.entries().isEmpty)
    #expect(try harness.fresh(ListItem.self).first?.label == "Orphelin")
  }

  @Test func screensReceiveTheMapping() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let oldId = list.id
    let received = Box<[UUID: UUID]>([:])
    let token = NotificationCenter.default.addObserver(forName: .syncDidRekeyData, object: nil, queue: nil) {
      received.value = IdentifierRemap(notification: $0)?.identifiers ?? [:]
    }
    defer { NotificationCenter.default.removeObserver(token) }
    await harness.gateway.setKnownAccount(UUID())
    await harness.engine.drain(pull: true)
    #expect(received.value[oldId] == list.id)
    #expect(list.id != oldId)
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

/// Horloge du téléphone en avance : refus `23514` corrigé par l'heure du serveur.
@MainActor
@Suite(.serialized) struct ClockCorrectionTests {
  @Test func aFastPhoneIsCorrectedWithoutFailingAnything() async throws {
    let harness = try SyncHarness()
    let serverNow = harness.clock.now
    harness.clock.advance(600)
    let device = harness.clock.now
    await harness.gateway.setServerNow(serverNow)
    await harness.gateway.setEnforcesClock(true)

    let list = try harness.lists.createList(name: "A", at: device)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: device)
    let visit = try harness.visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: device)
    try harness.visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: device)
    try harness.visits.addCheck(
      visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: device.addingTimeInterval(-10))
    try harness.visits.closeVisit(id: visit.id, at: device)
    await harness.engine.drain()

    #expect(try harness.entries().isEmpty)
    let sent = try #require(try harness.fresh(Visit.self).first)
    #expect(sent.syncState == .synced && sent.endSyncState == .synced)
    #expect(try harness.fresh(Check.self).allSatisfy { $0.syncState == .synced })
    #expect(await harness.gateway.visits.first?.startedAt == serverNow)
    // L'écart entre les coches survit à la correction.
    let dates = (await harness.gateway.checkBatches.flatMap { $0 }).map(\.checkedAt).sorted()
    #expect(dates == [serverNow.addingTimeInterval(-10), serverNow])
    #expect(await harness.gateway.closures == [serverNow])
    // Local : l'heure du téléphone reste, seul l'envoi est corrigé.
    #expect(visit.startedAt == device)
  }

  @Test func theShiftIsUniformAndCappedAtServerTime() {
    let server = t0
    let fixed = ServerClock(serverNow: server, deviceNow: server)
    #expect(fixed.shift(forLatest: server.addingTimeInterval(86_400)) == 86_400)
    #expect(fixed.shift(forLatest: server.addingTimeInterval(60)) == nil)
    let fast = ServerClock(serverNow: server, deviceNow: server.addingTimeInterval(600))
    #expect(fast.shift(forLatest: server.addingTimeInterval(590)) == 600)
  }

  /// Une coche sous la marge et une au-delà : les corriger séparément inverserait leur ordre.
  @Test func aMixedBatchKeepsItsOrderAndItsClosure() async throws {
    let harness = try SyncHarness()
    let serverNow = harness.clock.now
    let device = serverNow.addingTimeInterval(600)
    harness.clock.now = device
    await harness.gateway.setServerNow(serverNow)
    await harness.gateway.setEnforcesClock(true)
    let list = try harness.lists.createList(name: "A", at: device)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: device)
    let start = serverNow.addingTimeInterval(100)
    let visit = try harness.visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: start)
    let early = serverNow.addingTimeInterval(200)
    let late = serverNow.addingTimeInterval(400)
    try harness.visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: early)
    try harness.visits.addCheck(visitId: visit.id, itemId: item.id, subject: .category("dairy"), checkedAt: late)
    try harness.visits.closeVisit(id: visit.id, at: device)
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    let dates = (await harness.gateway.checkBatches.flatMap { $0 }).map(\.checkedAt)
    #expect(Set(dates) == [early.addingTimeInterval(-600), late.addingTimeInterval(-600)])
    #expect(await harness.gateway.closures == [serverNow])
  }

  @Test func theHTTPDateIsParsed() {
    #expect(ServerClock.parseHTTPDate("Sun, 06 Nov 1994 08:49:37 GMT") == Date(timeIntervalSince1970: 784_111_777))
    #expect(ServerClock.parseHTTPDate("pas une date") == nil)
  }

  @Test func anotherRefusalStaysDefinitive() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 1)
    let check = try #require(try all(harness, Check.self).first)
    await harness.gateway.setFailingCheck(check.id, error: .constraint(code: "23514"))
    await harness.engine.drain()
    #expect(try harness.fresh(Check.self).first?.syncState == .failed)
    #expect(try harness.fresh(Visit.self).first?.syncState == .synced)
    _ = seeded
  }

  /// Sans heure du serveur, le refus ne se corrige pas, mais la visite ne doit jamais être perdue.
  @Test func withoutServerTimeTheVisitIsSetAsideAndNeverFails() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 1)
    let other = try harness.lists.createList(name: "Autre", at: t0)
    await harness.gateway.setServerNow(nil)
    await harness.gateway.failAlways("createVisit", with: .constraint(code: "23514"))
    for _ in 0..<(SyncRetryPolicy.maxDependencyAttempts + 2) {
      await harness.engine.drain()
      harness.clock.advance(SyncRetryPolicy.parkedRetryDelay + 1)
    }
    let visit = try #require(try harness.fresh(Visit.self).first)
    #expect(visit.syncState == .pending)
    #expect(try harness.fresh(Check.self).first?.syncState == .pending)
    let entry = try #require(try harness.entries().first { $0.entityId == seeded.visit.id })
    #expect(entry.syncState == .pending && entry.attempts == 0)
    #expect(await harness.gateway.savedLists.contains { $0.id == other.id })
  }
}

/// Erreur serveur persistante sur une ligne : elle laisse passer le reste, sans jamais être abandonnée.
@MainActor
@Suite(.serialized) struct ParkedEntryTests {
  private func pass(_ harness: SyncHarness) async {
    await harness.skipBackoff()
    await harness.engine.drain()
  }

  private func elapseGrace(_ harness: SyncHarness) {
    harness.clock.advance(SyncRetryPolicy.serverFailureGrace + 1)
  }

  @Test func aFailingListBlocksEverythingUntilTheGraceEndsThenOnlyItsDependents() async throws {
    let harness = try SyncHarness()
    let bad = try harness.lists.createList(name: "Mauvaise", at: t0)
    let badItem = try harness.lists.addItem(
      listId: bad.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    let good = try harness.lists.createList(name: "Bonne", at: t0)
    await harness.gateway.setServerFailing([bad.id])

    await harness.engine.drain()
    #expect(await harness.gateway.savedLists.isEmpty)
    await pass(harness)
    #expect(await harness.gateway.savedLists.isEmpty)

    elapseGrace(harness)
    await pass(harness)
    #expect(await harness.gateway.savedLists.map(\.id) == [good.id])
    #expect(await harness.gateway.savedItems.isEmpty)
    #expect(bad.syncState == .pending && badItem.syncState == .pending)
    let parked = try #require(try harness.entries().first { $0.entityId == bad.id })
    #expect(parked.syncState == .pending && parked.attempts == 0)

    // Toujours en panne au nouvel essai : de côté tout de suite, sans rebloquer la file.
    await harness.gateway.clearCalls()
    harness.clock.advance(SyncRetryPolicy.parkedRetryDelay + 1)
    let other = try harness.lists.createList(name: "Autre", at: harness.clock.now)
    await harness.engine.drain()
    #expect(await harness.gateway.savedLists.last?.id == other.id)
    #expect(try harness.entries().first { $0.entityId == bad.id }?.attempts == 0)

    await harness.gateway.setServerFailing([])
    harness.clock.advance(SyncRetryPolicy.parkedRetryDelay + 1)
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    #expect(try harness.fresh(ShoppingList.self).allSatisfy { $0.syncState == .synced })
    #expect(try harness.fresh(ListItem.self).first?.syncState == .synced)
  }

  @Test func aFailingItemLetsItsSiblingsThrough() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let bad = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    let good = try harness.lists.addItem(
      listId: list.id, label: "Oeufs", normalizedName: "oeufs", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    await harness.gateway.setServerFailing([bad.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    #expect(await harness.gateway.savedItems.map(\.id) == [good.id])
    #expect(bad.syncState == .pending)
  }

  @Test func aDeletedListWaitsForAParkedItem() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    let bad = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0
    )
    await harness.gateway.setServerFailing([bad.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    let entry = try harness.entries().first { $0.entityId == bad.id }
    #expect(entry?.nextAttemptAt ?? t0 > harness.clock.now)
    // L'entrée de l'article part avec la suppression de la liste : rien ne reste bloqué.
    try harness.lists.deleteList(id: list.id, at: harness.clock.now)
    await harness.engine.drain()
    #expect(await harness.gateway.deletedLists == [list.id])
  }

  @Test func aFailingCheckIsIsolatedAndHoldsOnlyTheClosure() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 3)
    let checks = try all(harness, Check.self)
    let bad = try #require(checks.first)
    try harness.visits.closeVisit(id: seeded.visit.id, at: t0.addingTimeInterval(60))
    await harness.gateway.setServerFailing([bad.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)

    let sent = Set(await harness.gateway.checkBatches.flatMap { $0 }.map(\.id))
    #expect(sent == Set(checks.dropFirst().map(\.id)))
    #expect(await harness.gateway.closures.isEmpty)
    #expect(bad.syncState == .pending)
    #expect(seeded.visit.endSyncState == .pending)

    await harness.gateway.setServerFailing([])
    harness.clock.advance(SyncRetryPolicy.parkedRetryDelay + 1)
    await harness.engine.drain()
    #expect(await harness.gateway.closures.count == 1)
    #expect(try harness.entries().isEmpty)
  }

  @Test func aFailingVisitHoldsItsChecksAndClosure() async throws {
    let harness = try SyncHarness()
    let seeded = try harness.seedVisit(checks: 1)
    try harness.visits.closeVisit(id: seeded.visit.id, at: t0)
    let other = try harness.lists.createList(name: "Autre", at: t0)
    await harness.gateway.setServerFailing([seeded.visit.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    #expect(await harness.gateway.savedLists.contains { $0.id == other.id })
    #expect(await harness.gateway.checkBatches.isEmpty)
    #expect(await harness.gateway.closures.isEmpty)
    #expect(seeded.visit.syncState == .pending)
  }

  /// Panne générale : la ligne innocente mise de côté repart à la première preuve de reprise, sans attendre 6 h.
  @Test func aGlobalOutageReleasesTheInnocentRowOnRecovery() async throws {
    let harness = try SyncHarness()
    let innocent = try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.setServerFailing([innocent.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    #expect(try harness.entries().first?.nextAttemptAt ?? t0 > harness.clock.now)

    await harness.gateway.setServerFailing([])
    try harness.lists.createList(name: "B", at: harness.clock.now)
    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.savedLists.map(\.id).contains(innocent.id))
  }

  /// Une ligne vraiment fautive n'est réessayée qu'une fois : les succès suivants ne la relancent plus.
  @Test func aReallyFailingRowIsNotRetriedOnEverySuccess() async throws {
    let harness = try SyncHarness()
    let bad = try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.setServerFailing([bad.id])
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    try harness.lists.createList(name: "B", at: harness.clock.now)
    await harness.engine.drain()
    await harness.gateway.clearCalls()
    try harness.lists.createList(name: "C", at: harness.clock.now)
    await harness.engine.drain()
    #expect(await harness.gateway.calls.filter { $0 == "saveList" }.count == 1)
    #expect(try harness.entries().map(\.entityId) == [bad.id])
  }

  @Test func aNetworkOutageParksNothing() async throws {
    let harness = try SyncHarness()
    try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.failAlways("saveList", with: .network)
    await harness.engine.drain()
    elapseGrace(harness)
    await pass(harness)
    let entry = try #require(try harness.entries().first)
    #expect(entry.serverFailingSince == nil)
    #expect(entry.nextAttemptAt <= harness.clock.now)
  }

  /// Le départ de la panne survit à une modification : sinon, renommer rebloquerait toute la file pour des heures.
  @Test func anEditKeepsTheFailureStart() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    await harness.gateway.setServerFailing([list.id])
    await harness.engine.drain()
    let since = try #require(try harness.entries().first?.serverFailingSince)
    try harness.lists.renameList(id: list.id, name: "B", at: t0)
    #expect(try harness.entries().first?.serverFailingSince == since)
  }

  @Test func theFailureStartSurvivesARestart() async throws {
    let harness = try SyncHarness()
    let bad = try harness.lists.createList(name: "A", at: t0)
    let good = try harness.lists.createList(name: "B", at: t0)
    await harness.gateway.setServerFailing([bad.id])
    await harness.engine.drain()
    elapseGrace(harness)
    let restarted = harness.makeEngine()
    await restarted.drain()
    #expect(await harness.gateway.savedLists.map(\.id) == [good.id])
  }
}
