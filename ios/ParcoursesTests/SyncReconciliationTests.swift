import Foundation
import SwiftData
import Testing

@testable import Parcourses

private let t0 = syncEpoch

/// Premières courses réelles (nov. 2026) : liste créée avant la file, 9 articles abandonnés en `42501`.
@MainActor
@Suite(.serialized) struct SyncReconciliationTests {
  /// Reproduit exactement l'état de l'iPhone : liste `pending` sans entrée, un `upsertItem` `failed` (42501,
  /// 0 essai) par article.
  private func seedDeviceState(_ harness: SyncHarness) throws -> (list: ShoppingList, items: [ListItem]) {
    let list = try harness.lists.createList(name: "Courses", at: t0)
    var items: [ListItem] = []
    for label in [
      "Moutarde", "Papier toilette", "Lessive", "Lait", "Whey", "Cornichons", "Viande", "Saucisse", "Tomate",
    ] {
      items.append(
        try harness.lists.addItem(
          listId: list.id, label: label, normalizedName: label.lowercased(), quantity: nil, productId: nil,
          categoryId: "other", at: t0))
    }
    for entry in try harness.entries() {
      if entry.kind == .upsertList {
        harness.context.delete(entry)
      } else {
        entry.syncState = .failed
        entry.lastError = "42501"
      }
    }
    for item in items { item.syncState = .failed }
    try harness.context.save()
    return (list, items)
  }

  @Test func theListAndItsNineItemsReachTheServerWithoutAnyAction() async throws {
    let harness = try SyncHarness()
    let (list, items) = try seedDeviceState(harness)
    await harness.gateway.setItemsNeedTheirList(true)
    #expect(try harness.entries().filter { $0.kind == .upsertList }.isEmpty)
    #expect(try harness.entries().filter { $0.syncState == .failed }.count == 9)

    // Un nouveau moteur, comme au relancement de l'app.
    await harness.engine.drain()

    #expect(await harness.gateway.savedLists.map(\.id) == [list.id])
    #expect(Set(await harness.gateway.savedItems.map(\.id)) == Set(items.map(\.id)))
    #expect(try harness.entries().isEmpty)
    #expect(try harness.fresh(ShoppingList.self).allSatisfy { $0.syncState == .synced })
    #expect(try harness.fresh(ListItem.self).allSatisfy { $0.syncState == .synced })
  }

  @Test func theListIsQueuedBeforeItsItems() async throws {
    let harness = try SyncHarness()
    _ = try seedDeviceState(harness)
    let queued = try OutboxReconciliation.run(in: harness.context, now: t0)
    #expect(queued == 10)
    let entries = try harness.entries()
    #expect(entries.count == 10)
    #expect(entries.first?.kind == .upsertList)
    #expect(entries.allSatisfy { $0.syncState == .pending })
    #expect(entries.dropFirst().allSatisfy { $0.kind == .upsertItem })
  }

  @Test func reconciliationIsIdempotent() throws {
    let harness = try SyncHarness()
    _ = try seedDeviceState(harness)
    try OutboxReconciliation.run(in: harness.context, now: t0)
    let before = try harness.entries().map(\.id)
    #expect(try OutboxReconciliation.run(in: harness.context, now: t0) == 0)
    #expect(try harness.entries().map(\.id) == before)
  }

  @Test func visitsChecksAndClosuresWithoutEntryAreQueuedInOrder() throws {
    let harness = try SyncHarness()
    let (_, visit) = try harness.seedVisit(checks: 2)
    try harness.visits.closeVisit(id: visit.id, at: t0.addingTimeInterval(60))
    for entry in try harness.entries() where entry.kind != .upsertList && entry.kind != .upsertItem {
      harness.context.delete(entry)
    }
    try harness.context.save()

    try OutboxReconciliation.run(in: harness.context, now: t0)
    #expect(try harness.kinds() == [.upsertList, .upsertItem, .createVisit, .insertChecks, .insertChecks, .closeVisit])
    #expect(try OutboxReconciliation.run(in: harness.context, now: t0) == 0)
  }

  @Test func aVisitWithoutCheckStaysLocal() throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "A", at: t0)
    _ = try harness.visits.startVisit(storeId: UUID(), listId: list.id, listWasSorted: false, at: t0)
    try OutboxReconciliation.run(in: harness.context, now: t0)
    #expect(try harness.kinds() == [.upsertList])
  }

  @Test func aForbiddenItemWaitsForItsListInsteadOfFailing() async throws {
    let harness = try SyncHarness()
    await harness.gateway.setItemsNeedTheirList(true)
    // La réconciliation de lancement a déjà eu lieu : seule la parade au refus peut encore intervenir.
    await harness.engine.drain()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    for entry in try harness.entries() where entry.kind == .upsertList { harness.context.delete(entry) }
    try harness.context.save()

    await harness.engine.drain()
    #expect(try harness.entries().filter { $0.syncState == .failed }.isEmpty)
    #expect(try harness.entries().first { $0.kind == .upsertItem }?.attempts == 0)

    await harness.skipBackoff()
    harness.clock.advance(SyncRetryPolicy.listWaitDelay * 2)
    await harness.engine.drain()
    #expect(await harness.gateway.savedLists.map(\.id) == [list.id])
    #expect(await harness.gateway.savedItems.map(\.id) == [item.id])
    #expect(try harness.entries().isEmpty)
  }

  @Test func aFailedItemWhoseListWasReceivedStaysFailed() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    _ = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    await harness.gateway.failAlways("saveItem", with: .forbidden)
    await harness.engine.drain()
    #expect(try harness.entries().filter { $0.syncState == .failed }.count == 1)
    #expect(try harness.fresh(ShoppingList.self).first?.syncState == .synced)
    // Ne revient pas indéfiniment : la réconciliation ne rend pas un vrai refus.
    #expect(try OutboxReconciliation.run(in: harness.context, now: t0) == 0)
  }
}
