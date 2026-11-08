import Foundation
import SwiftData
import Testing

@testable import Parcourses

private nonisolated let t0 = syncEpoch

/// Apprentissage sans catalogue : un article saisi librement reçoit son produit avant l'envoi.
@MainActor
@Suite(.serialized) struct ProductResolutionTests {
  private func resolved(_ id: UUID, _ name: String, slug: String? = "dairy") -> ResolvedProductRow {
    ResolvedProductRow(normalizedName: name.lowercased(), id: id, name: name, categorySlug: slug)
  }

  @Test func aFreeItemAndItsQueuedChecksLeaveWithTheirProduct() async throws {
    let harness = try SyncHarness()
    let (_, visit) = try harness.seedVisit(checks: 2)
    let productId = UUID()
    await harness.gateway.setResolvable(["Lait": resolved(productId, "Lait")])

    await harness.engine.drain()

    let requests = await harness.gateway.resolveRequests
    #expect(requests.count == 1)
    #expect(requests.first?.count == 1)
    #expect(requests.first?.first?.name == "Lait")
    #expect(requests.first?.first?.categorySlug == "dairy")
    #expect(await harness.gateway.savedItems.last?.productId == productId)
    let targets = await harness.gateway.checkBatches.flatMap { $0.map(\.target) }
    #expect(targets == [.product(productId), .product(productId)])

    let item = try #require(harness.fresh(ListItem.self).first)
    #expect(item.productId == productId)
    // La catégorie locale ne bouge pas : l'article reste à sa place.
    #expect(item.categoryId == "dairy")
    let checks = try harness.visits.checks(visitId: visit.id)
    #expect(checks.allSatisfy { $0.productId == productId && $0.categoryId == nil && $0.syncState == .synced })
    let product = try #require(harness.fresh(Product.self).first { $0.id == productId })
    #expect(product.name == "Lait")
    #expect(try harness.entries().isEmpty)
  }

  @Test func aLabelWithoutProductIsAskedOncePerRun() async throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    try harness.lists.addItem(
      listId: list.id, label: "Graines de chia", normalizedName: "graine chia", quantity: nil, productId: nil,
      categoryId: "bio", at: t0)
    await harness.engine.drain()
    await harness.engine.drain(pull: true)
    #expect(await harness.gateway.resolveRequests.map { $0.map(\.name) } == [["Graines de chia"]])
    #expect(try harness.fresh(ListItem.self).first?.productId == nil)

    // Un nouvel article part seul ; un nouveau lancement redemande l'ancien.
    try harness.lists.addItem(
      listId: list.id, label: "Kombucha", normalizedName: "kombucha", quantity: nil, productId: nil,
      categoryId: "beverages", at: t0)
    await harness.engine.drain()
    #expect(await harness.gateway.resolveRequests.last?.map(\.name) == ["Kombucha"])
    await harness.makeEngine().drain()
    #expect(await Set(harness.gateway.resolveRequests.last?.map(\.name) ?? []) == ["Graines de chia", "Kombucha"])
  }

  @Test func aFailedResolutionNeverHoldsTheQueue() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    await harness.gateway.failAlways("resolveProducts", with: .server(code: "500"))

    await harness.engine.drain()
    // Envoyé tel quel : la coche désigne sa catégorie.
    #expect(try harness.entries().isEmpty)
    let targets = await harness.gateway.checkBatches.flatMap { $0.map(\.target) }
    #expect(targets == [.category(slug: "dairy")])

    // La résolution attend seule, puis reprend ; une coche déjà partie n'est pas réécrite.
    let productId = UUID()
    await harness.gateway.failAlways("resolveProducts", with: nil)
    await harness.gateway.setResolvable(["Lait": resolved(productId, "Lait")])
    await harness.engine.drain()
    #expect(await harness.gateway.resolveRequests.isEmpty)
    harness.clock.advance(SyncRetryPolicy.resolutionRetryInterval * 2)
    await harness.engine.drain()
    #expect(await harness.gateway.resolveRequests.count == 1)
    #expect(await harness.gateway.savedItems.last?.productId == productId)
    #expect(try harness.fresh(Check.self).allSatisfy { $0.categoryId == "dairy" && $0.productId == nil })
  }

  /// App livrée avant la migration du serveur : `PGRST202` ne retient pas la file et se réessaie vite.
  @Test func aMissingFunctionRetriesSoonWithoutHoldingTheQueue() async throws {
    let harness = try SyncHarness()
    try harness.seedVisit()
    await harness.gateway.failAlways("resolveProducts", with: .rejected(code: RemoteError.functionNotFoundCode))

    await harness.engine.drain()
    #expect(try harness.entries().isEmpty)
    #expect(await harness.gateway.checkBatches.flatMap { $0.map(\.target) } == [.category(slug: "dairy")])

    // Migration appliquée : rien avant le délai, puis reprise bien avant l'heure d'un refus définitif.
    let productId = UUID()
    await harness.gateway.failAlways("resolveProducts", with: nil)
    await harness.gateway.setResolvable(["Lait": resolved(productId, "Lait")])
    harness.clock.advance(SyncRetryPolicy.resolutionUnavailableInterval - 10)
    await harness.engine.drain()
    #expect(await harness.gateway.resolveRequests.isEmpty)
    harness.clock.advance(20)
    await harness.engine.drain()
    #expect(await harness.gateway.resolveRequests.count == 1)
    #expect(await harness.gateway.savedItems.last?.productId == productId)
  }

  @Test func theResolutionDelayDependsOnTheError() {
    #expect(SyncRetryPolicy.resolutionUnavailableInterval < SyncRetryPolicy.resolutionRejectedInterval)
    #expect(
      SyncRetryPolicy.resolutionDelay(after: RemoteError.rejected(code: "PGRST202"))
        == SyncRetryPolicy.resolutionUnavailableInterval)
    #expect(
      SyncRetryPolicy.resolutionDelay(after: RemoteError.rejected(code: "22023"))
        == SyncRetryPolicy.resolutionRejectedInterval)
    #expect(SyncRetryPolicy.resolutionDelay(after: RemoteError.network) == SyncRetryPolicy.resolutionRetryInterval)
    #expect(
      SyncRetryPolicy.resolutionDelay(after: RemoteError.server(code: "500")) == SyncRetryPolicy.resolutionRetryInterval
    )
    // Le code PostgREST arrive bien ainsi du gateway.
    #expect(RemoteError.fromPostgrest(code: "PGRST202") == .rejected(code: RemoteError.functionNotFoundCode))
  }

  @Test func aCorrectedClockSurvivesTheRewrite() throws {
    let harness = try SyncHarness()
    let (_, visit) = try harness.seedVisit()
    let entry = try #require(harness.entries().first { $0.kind == .insertChecks })
    let shifted = t0.addingTimeInterval(-120)
    entry.payload = try OutboxCoding.encode(
      OutboxCoding.decode(CheckPayload.self, from: entry.payload).with(checkedAt: shifted))
    try harness.context.save()
    let item = try #require(harness.lists.items(listId: visit.listId).first)
    let candidate = ProductCandidate(itemId: item.id, label: "Lait", categorySlug: "dairy")
    let productId = UUID()
    let match = try #require(ProductMatch(candidate, resolved(productId, "Lait")))

    #expect(try ProductResolution.apply([match], in: harness.context, at: t0))

    let payload = try OutboxCoding.decode(CheckPayload.self, from: entry.payload)
    #expect(payload.productId == productId)
    #expect(payload.categoryId == nil)
    #expect(payload.checkedAt == shifted)
  }

  @Test func anEditedOrDeletedItemIgnoresTheAnswer() throws {
    let harness = try SyncHarness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let item = try harness.lists.addItem(
      listId: list.id, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    let other = try harness.lists.createList(name: "Autre", at: t0)
    let gone = try harness.lists.addItem(
      listId: other.id, label: "Pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery",
      at: t0)
    try harness.lists.deleteList(id: other.id, at: t0)
    #expect(
      try ProductResolution.candidates(in: harness.context, excluding: [:], limit: 100).map(\.itemId) == [item.id])

    let stale = try #require(
      ProductMatch(
        ProductCandidate(itemId: item.id, label: "Lai", categorySlug: "dairy"), resolved(UUID(), "Lai")))
    let deleted = try #require(
      ProductMatch(
        ProductCandidate(itemId: gone.id, label: "Pain", categorySlug: "bakery"), resolved(UUID(), "Pain")))
    #expect(try ProductResolution.apply([stale, deleted], in: harness.context, at: t0) == false)
    #expect(item.productId == nil)
  }
}
