import Domain
import Foundation
import SwiftData
import Testing

@testable import Parcourses

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Panneau de l'article et saisie sur un article existant (#110).
@MainActor
@Suite struct ItemEditTests {
  private struct Harness {
    let context: ModelContext
    let environment: AppEnvironment
    let lists: SwiftDataListRepository
    let listId: UUID

    init() throws {
      let container = try PersistenceStack.makeContainer(storage: .inMemory)
      context = container.mainContext
      environment = try AppEnvironment(container: container)
      lists = SwiftDataListRepository(context: context)
      listId = try lists.createList(name: "L", at: t0).id
    }

    func detail() -> ListDetailModel {
      let model = environment.makeListDetailModel(listId: listId)
      model.load()
      return model
    }

    func item(_ id: UUID) throws -> ListItem {
      try #require(try lists.items(listId: listId).first { $0.id == id })
    }

    /// Champs de la dernière entrée d'article en file.
    func queuedFields(_ id: UUID) throws -> [String]? {
      let kind = OutboxKind.upsertItem.rawValue
      return try context.fetch(
        FetchDescriptor<OutboxEntry>(predicate: #Predicate { $0.entityId == id && $0.kindRaw == kind })
      ).last?.changedFields
    }

    /// Article marqué comme parti au serveur, sans entrée en attente : seuls les nouveaux champs comptent.
    func markSent(_ id: UUID) throws {
      try context.fetch(FetchDescriptor<OutboxEntry>()).forEach(context.delete)
      try item(id).isOnServer = true
      try context.save()
    }
  }

  // MARK: - Dépôt

  @Test func quantityChangeSendsOnlyTheQuantity() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "Lait", normalizedName: "lait", quantity: nil, productId: UUID(), categoryId: "dairy",
      at: t0)
    try h.markSent(milk.id)

    try h.lists.updateItem(
      itemId: milk.id, label: "Lait", normalizedName: "lait", categoryId: "dairy", quantity: "2", at: t0 + 5)
    let item = try h.item(milk.id)
    #expect(item.quantity == "2")
    #expect(item.productId != nil)
    #expect(item.updatedAt == t0 + 5)
    #expect(try h.queuedFields(milk.id) == [ListItemFields.quantity])
  }

  @Test func renamingReclassifiesAndForgetsTheProduct() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "Lait", normalizedName: "lait", quantity: "1", productId: UUID(), categoryId: "dairy",
      at: t0)
    try h.markSent(milk.id)

    try h.lists.apply(
      try #require(ItemEdit(label: "  tomates ", quantityText: "1")), to: milk.id,
      analyzer: try EntryAnalyzer(), at: t0 + 5)
    let item = try h.item(milk.id)
    #expect(item.label == "tomates")
    #expect(item.normalizedName == "tomate")
    #expect(item.categoryId == "produce")
    #expect(item.productId == nil)
    #expect(try h.queuedFields(milk.id) == [ListItemFields.label, ListItemFields.productId])
  }

  /// Même forme normalisée (casse) : le produit reste celui de l'article.
  @Test func renamingWithTheSameFormKeepsTheProduct() throws {
    let h = try Harness()
    let product = UUID()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "lait", normalizedName: "lait", quantity: nil, productId: product, categoryId: "dairy",
      at: t0)
    try h.markSent(milk.id)

    try h.lists.apply(
      try #require(ItemEdit(label: "Lait", quantityText: "")), to: milk.id, analyzer: try EntryAnalyzer(), at: t0)
    #expect(try h.item(milk.id).productId == product)
    #expect(try h.queuedFields(milk.id) == [ListItemFields.label])
  }

  @Test func anUnchangedItemWritesNothing() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "Lait", normalizedName: "lait", quantity: "2", productId: nil, categoryId: "dairy",
      at: t0)
    try h.markSent(milk.id)

    try h.lists.updateItem(
      itemId: milk.id, label: "Lait", normalizedName: "lait", categoryId: "dairy", quantity: "2", at: t0 + 5)
    #expect(try h.context.fetchCount(FetchDescriptor<OutboxEntry>()) == 0)
    #expect(try h.item(milk.id).updatedAt == t0)
  }

  @Test func editFormIsCleaned() {
    #expect(ItemEdit(label: "   ", quantityText: "2") == nil)
    let edit = ItemEdit(label: " Lait ", quantityText: "  500   g ")
    #expect(edit?.label == "Lait")
    #expect(edit?.quantity == "500 g")
    #expect(ItemEdit(label: "Lait", quantityText: "  ")?.quantity == nil)
  }

  // MARK: - Écran Liste

  @Test func anEntryWithAQuantityUpdatesTheExistingItem() throws {
    let h = try Harness()
    let model = h.detail()
    model.input = "lait"
    #expect(model.submit().map { if case .added = $0 { true } else { false } } == true)
    let milk = try #require(model.sections.first?.items.first)

    model.input = "laits x3"
    #expect(model.submit() == .updated(milk.id))
    #expect(model.input.isEmpty)
    let items = try h.lists.items(listId: h.listId)
    #expect(items.count == 1)
    #expect(items[0].quantity == "3")
    #expect(items[0].label == "lait")
  }

  @Test func anEntryWithoutQuantityOrOnACheckedItemIsAdded() throws {
    let h = try Harness()
    let model = h.detail()
    model.input = "2 tomates"
    model.submit()
    model.input = "tomates"
    model.submit()
    #expect(try h.lists.items(listId: h.listId).count == 2)

    for row in model.sections.flatMap(\.items) { model.toggle(row) }
    model.input = "3 tomates"
    model.submit()
    #expect(try h.lists.items(listId: h.listId).count == 3)
  }

  @Test func savingTheSheetMovesTheItemToItsNewAisle() throws {
    let h = try Harness()
    let model = h.detail()
    model.input = "lait"
    model.submit()
    let row = try #require(model.sections.first?.items.first)
    let target = try #require(model.editTarget(for: row))
    #expect(target == ItemEditTarget(id: row.id, label: "lait", quantity: nil))

    model.save(try #require(ItemEdit(label: "pommes", quantityText: "1,5 kg")), for: target.id)
    #expect(model.sections.map(\.categoryId) == ["produce"])
    let moved = try #require(model.sections.first?.items.first)
    #expect(moved.label == "pommes")
    #expect(moved.quantity == "1,5 kg")
  }

  @Test func aViewerCannotEdit() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "Lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    try #require(try h.lists.list(id: h.listId)).role = .viewer
    try h.context.save()
    let model = h.detail()
    let row = try #require(model.sections.first?.items.first)
    #expect(model.editTarget(for: row) == nil)
    model.save(try #require(ItemEdit(label: "Lait", quantityText: "2")), for: milk.id)
    #expect(try h.item(milk.id).quantity == nil)
    model.input = "lait x2"
    #expect(model.submit() == nil)
  }

  // MARK: - Mode courses

  private func shopping(_ h: Harness) throws -> ShoppingSession {
    let categories = SwiftDataCategoryRepository(context: h.context)
    let stores = SwiftDataStoreRepository(context: h.context)
    let storeId = UUID()
    try stores.upsertStore(
      id: storeId, name: "Leclerc", chain: nil, address: nil, lastDistanceM: nil, organicAisle: false)
    return ShoppingSession(
      listId: h.listId, storeId: storeId, lists: h.lists, visits: SwiftDataVisitRepository(context: h.context),
      stores: stores, categories: categories, analyzer: try EntryAnalyzer(),
      cache: GraphSnapshotCache(graphs: SwiftDataGraphRepository(context: h.context), gateway: nil),
      settleDelay: .milliseconds(1), highlightDelay: .seconds(60))
  }

  @Test func shoppingSavesTheSheetAndMergesEntries() async throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    let session = try shopping(h)
    await session.start()

    session.save(try #require(ItemEdit(label: "lait", quantityText: "2")), for: milk.id)
    #expect(session.toBuy.first?.quantity == "2")

    session.input = "lait x4"
    await session.submit()
    #expect(session.input.isEmpty)
    #expect(session.toBuy.count == 1)
    #expect(session.toBuy.first?.quantity == "4")
    #expect(session.highlightedItemId == milk.id)
  }
}
