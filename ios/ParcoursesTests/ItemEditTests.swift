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

    let target = ItemEditTarget(id: milk.id, label: "Lait", quantity: "1")
    try h.lists.apply(
      try #require(ItemEdit(target: target, label: "  tomates ", quantityText: "1")), to: milk.id,
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

    let target = ItemEditTarget(id: milk.id, label: "lait", quantity: nil)
    try h.lists.apply(
      try #require(ItemEdit(target: target, label: "Lait", quantityText: "")), to: milk.id,
      analyzer: try EntryAnalyzer(), at: t0)
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
    let target = ItemEditTarget(id: UUID(), label: "Lait", quantity: "2")
    #expect(ItemEdit(target: target, label: "   ", quantityText: "2") == nil)
    // Rien de changé par rapport à l'ouverture : rien à écrire.
    #expect(ItemEdit(target: target, label: " Lait ", quantityText: " 2 ")?.isEmpty == true)
    let edit = ItemEdit(target: target, label: " Lait ", quantityText: "  500   g ")
    #expect(edit?.label == nil)
    #expect(edit?.changesQuantity == true)
    #expect(edit?.quantity == "500 g")
    let cleared = ItemEdit(target: target, label: "Lait", quantityText: "  ")
    #expect(cleared?.changesQuantity == true && cleared?.quantity == nil)
    // Retour à la ligne (collé) : une espace, le libellé tient sur une ligne.
    #expect(ItemEdit(target: target, label: "Lait\nbio\n", quantityText: "2")?.label == "Lait bio")
    #expect(ItemEdit(target: target, label: "lait\r\n\u{2028}bio", quantityText: "2")?.label == "lait bio")
    // Coupé à 200 points de code (`char_length`), pas à 200 graphèmes : un drapeau en compte deux.
    let flags = String(repeating: "🇫🇷", count: 150)
    #expect(ItemEdit(target: target, label: flags, quantityText: "2")?.label?.unicodeScalars.count == 200)
  }

  /// Saisie du libellé : « Terminé » au curseur ou avec une correction automatique, collage, limite de 200 points de
  /// code (refusée au-delà, comme Android).
  @Test func labelInputHandlesDoneKeyPasteAndLimit() {
    #expect(ItemEdit.labelInput(old: "Lait", new: "La\nit") == ("Lait", true))
    #expect(ItemEdit.labelInput(old: "Lait", new: "Lait\n") == ("Lait", true))
    // Correction automatique « lai » → « lait » en même temps que « Terminé » : la correction reste.
    #expect(ItemEdit.labelInput(old: "lai", new: "lait\n") == ("lait", true))
    #expect(ItemEdit.labelInput(old: "", new: "lait\r\nbio") == ("lait bio", false))
    #expect(ItemEdit.labelInput(old: "Lait", new: "Lait bio") == ("Lait bio", false))
    let full = String(repeating: "🥛", count: 200)
    #expect(ItemEdit.labelInput(old: full, new: full + "x") == (full, false))
    #expect(ItemEdit.labelInput(old: String(repeating: "🥛", count: 199), new: full) == (full, false))
    // Déjà trop long (venu d'ailleurs) : il se raccourcit normalement.
    let long = full + "ab"
    #expect(ItemEdit.labelInput(old: long, new: full + "a") == (full + "a", false))
    // Quantité : même limite, en points de code (un drapeau en compte deux).
    let flags = String(repeating: "🇫🇷", count: 25)
    #expect(ItemEdit.limited(old: flags, new: flags + "1", max: ItemQuantity.maxLength) == flags)
  }

  /// Le libellé renommé par un autre membre pendant que le panneau était ouvert n'est pas annulé par un changement de
  /// quantité, et inversement.
  @Test func onlyTheFieldsChangedInTheSheetAreWritten() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    let opened = ItemEditTarget(id: milk.id, label: "lait", quantity: nil)
    // Arrivé d'ailleurs pendant que le panneau est ouvert.
    milk.label = "lait d'avoine"
    milk.normalizedName = "lait avoine"
    try h.context.save()
    try h.markSent(milk.id)

    try h.lists.apply(
      try #require(ItemEdit(target: opened, label: "lait", quantityText: "2")), to: milk.id,
      analyzer: try EntryAnalyzer(), at: t0 + 5)
    let item = try h.item(milk.id)
    #expect(item.label == "lait d'avoine")
    #expect(item.quantity == "2")
    #expect(try h.queuedFields(milk.id) == [ListItemFields.quantity])
  }

  /// Forme normalisée changée : `product_id` part à `null` même sans produit local (le serveur peut en avoir un).
  @Test func aNewFormAlwaysClearsTheServerProduct() throws {
    let h = try Harness()
    let milk = try h.lists.addItem(
      listId: h.listId, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy",
      at: t0)
    try h.markSent(milk.id)
    try h.lists.updateItem(
      itemId: milk.id, label: "beurre", normalizedName: "beurre", categoryId: "dairy", quantity: nil, at: t0 + 5)
    #expect(try h.queuedFields(milk.id) == [ListItemFields.label, ListItemFields.productId])
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

    model.save(try #require(ItemEdit(target: target, label: "pommes", quantityText: "1,5 kg")), for: target.id)
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
    let target = ItemEditTarget(id: milk.id, label: "Lait", quantity: nil)
    model.save(try #require(ItemEdit(target: target, label: "Lait", quantityText: "2")), for: milk.id)
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

    let target = ItemEditTarget(id: milk.id, label: "lait", quantity: nil)
    session.save(try #require(ItemEdit(target: target, label: "lait", quantityText: "2")), for: milk.id)
    #expect(session.toBuy.first?.quantity == "2")

    session.input = "lait x4"
    await session.submit()
    #expect(session.input.isEmpty)
    #expect(session.toBuy.count == 1)
    #expect(session.toBuy.first?.quantity == "4")
    #expect(session.highlightedItemId == milk.id)
    // Tri différé terminé avant la fin du test : il lit le stockage, libéré ensuite.
    await session.waitUntilSettled()
  }
}
