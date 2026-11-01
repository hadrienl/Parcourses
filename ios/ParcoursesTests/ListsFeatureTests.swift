import Domain
import Foundation
import SwiftData
import Testing

@testable import Parcourses

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private struct Harness {
  let context: ModelContext
  let environment: AppEnvironment
  let lists: SwiftDataListRepository

  init() throws {
    let container = try PersistenceStack.makeContainer(storage: .inMemory)
    context = container.mainContext
    environment = try AppEnvironment(container: container)
    lists = SwiftDataListRepository(context: context)
  }

  func detail(_ id: UUID) -> ListDetailModel {
    let model = environment.makeListDetailModel(listId: id)
    model.load()
    return model
  }
}

/// Compte les lectures, le reste passe au vrai repository.
@MainActor
private final class SpyHistory: ListRepository {
  let base: any ListRepository
  var historyCalls = 0
  var itemsCalls = 0

  init(base: any ListRepository) { self.base = base }

  func itemHistory() throws -> [ListItem] {
    historyCalls += 1
    return try base.itemHistory()
  }
  func items(listId: UUID) throws -> [ListItem] {
    itemsCalls += 1
    return try base.items(listId: listId)
  }
  func lists() throws -> [ShoppingList] { try base.lists() }
  func list(id: UUID) throws -> ShoppingList? { try base.list(id: id) }
  func createList(name: String, at date: Date) throws -> ShoppingList { try base.createList(name: name, at: date) }
  func renameList(id: UUID, name: String, at date: Date) throws { try base.renameList(id: id, name: name, at: date) }
  func deleteList(id: UUID, at date: Date) throws { try base.deleteList(id: id, at: date) }
  func addItem(
    listId: UUID, label: String, normalizedName: String, quantity: String?, productId: UUID?, categoryId: String,
    at date: Date
  ) throws -> ListItem {
    try base.addItem(
      listId: listId, label: label, normalizedName: normalizedName, quantity: quantity, productId: productId,
      categoryId: categoryId, at: date)
  }
  func setChecked(itemId: UUID, checkedAt: Date?, at date: Date) throws {
    try base.setChecked(itemId: itemId, checkedAt: checkedAt, at: date)
  }
  func setNotFound(itemId: UUID, notFoundAt: Date?, at date: Date) throws {
    try base.setNotFound(itemId: itemId, notFoundAt: notFoundAt, at: date)
  }
  func deleteItem(id: UUID) throws { try base.deleteItem(id: id) }
}

@MainActor
@Suite struct ListsModelTests {
  @Test func createRenameDeleteAndCounts() throws {
    let h = try Harness()
    let model = h.environment.makeListsModel()
    model.load()
    #expect(model.lists.isEmpty)
    #expect(!ListsModel.isValid(name: "  "))
    #expect(model.create(name: "   ") == nil)

    let id = try #require(model.create(name: "  Semaine "))
    #expect(model.lists.map(\.name) == ["Semaine"])
    #expect(model.lists[0].subtitle == "Aucun article")

    let item = try h.lists.addItem(
      listId: id, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    try h.lists.addItem(
      listId: id, label: "pain", normalizedName: "pain", quantity: nil, productId: nil, categoryId: "bakery", at: t0)
    model.load()
    #expect(model.lists[0].subtitle == "2 articles restants")
    try h.lists.setChecked(itemId: item.id, checkedAt: t0, at: t0)
    model.load()
    #expect(model.lists[0].subtitle == "1 article restant")

    model.rename(id: id, name: "Week-end")
    #expect(model.lists[0].name == "Week-end")
    model.rename(id: id, name: " ")
    #expect(model.lists[0].name == "Week-end")

    model.delete(id: id)
    #expect(model.lists.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test func writeFailureIsReported() throws {
    let h = try Harness()
    let model = h.environment.makeListsModel()
    model.delete(id: UUID())
    #expect(model.errorMessage == "L'opération a échoué : Cet élément n'existe plus.")
  }
}

@MainActor
@Suite struct ListDetailModelTests {
  @Test func quickEntryParsesClassifiesAndGroupsByRank() throws {
    let h = try Harness()
    let id = try h.lists.createList(name: "L", at: t0).id
    let model = h.detail(id)
    #expect(model.isEmpty)

    for text in ["2 laits demi-écrémé", "tomates", "xyzzy", "   "] {
      model.input = text
      model.submit()
    }
    #expect(model.sections.map(\.categoryId) == ["produce", "dairy", "other"])
    #expect(model.sections.map(\.items.count) == [1, 1, 1])
    #expect(model.sections[1].title == "Crèmerie, œufs, ultra-frais")
    let milk = model.sections[1].items[0]
    #expect(milk.label == "laits demi-écrémé")
    #expect(milk.quantity == "2")
    #expect(milk.accessibilityLabel == "laits demi-écrémé, 2")
    #expect(milk.accessibilityState == "non coché")
    #expect(model.input == "   ")
  }

  @Test func toggleAndDeleteArePersisted() throws {
    let h = try Harness()
    let id = try h.lists.createList(name: "L", at: t0).id
    let model = h.detail(id)
    model.input = "tomates"
    model.submit()
    let row = model.sections[0].items[0]

    model.toggle(row)
    #expect(try h.lists.items(listId: id)[0].checkedAt != nil)
    #expect(model.sections[0].items[0].accessibilityState == "coché")

    model.toggle(model.sections[0].items[0])
    #expect(try h.lists.items(listId: id)[0].checkedAt == nil)

    model.delete(model.sections[0].items[0])
    #expect(try h.lists.items(listId: id).isEmpty)
    #expect(model.isEmpty)
  }

  /// Décision produit : une saisie ajoute toujours une ligne, sans fusion des doublons.
  @Test func sameEntryTwiceAddsTwoRows() throws {
    let h = try Harness()
    let id = try h.lists.createList(name: "L", at: t0).id
    let model = h.detail(id)
    for _ in 0..<2 {
      model.input = "2 tomates"
      model.submit()
    }
    #expect(model.sections.map(\.items.count) == [2])
    #expect(try h.lists.items(listId: id).count == 2)
  }

  @Test func unknownOrDeletedListIsMissing() throws {
    let h = try Harness()
    #expect(h.detail(UUID()).isMissing)
    let id = try h.lists.createList(name: "L", at: t0).id
    #expect(!h.detail(id).isMissing)
    try h.lists.deleteList(id: id, at: t0)
    #expect(h.detail(id).isMissing)
  }

  @Test func initDoesNoIOAndToggleKeepsTheIndex() throws {
    let h = try Harness()
    let id = try h.lists.createList(name: "L", at: t0).id
    let spy = SpyHistory(base: h.lists)
    let model = ListDetailModel(
      listId: id, lists: spy, products: SwiftDataProductRepository(context: h.context),
      categories: SwiftDataCategoryRepository(context: h.context), analyzer: try EntryAnalyzer())
    #expect(spy.itemsCalls == 0 && spy.historyCalls == 0)

    model.load()
    #expect(spy.historyCalls == 1)
    model.input = "tomates"
    model.submit()
    #expect(spy.historyCalls == 2)
    let itemsCalls = spy.itemsCalls
    model.toggle(model.sections[0].items[0])
    #expect(spy.historyCalls == 2)
    #expect(spy.itemsCalls > itemsCalls)
    model.delete(model.sections[0].items[0])
    #expect(spy.historyCalls == 3)
  }

  @Test func suggestionOrderIgnoresFetchOrder() throws {
    func item(_ label: String, _ name: String) -> ListItem {
      ListItem(listId: UUID(), label: label, normalizedName: name, categoryId: "dairy", position: 0, updatedAt: t0)
    }
    let older = item("Lait", "lait")
    let newer = item("LAIT", "lait")
    let other = item("Laitue", "laitue")
    let a = ItemSuggestionIndex(history: [older, newer, other], products: [], normalizeFallback: { $0 })
    let b = ItemSuggestionIndex(history: [other, newer, older], products: [], normalizeFallback: { $0 })
    let first = a.suggestions(forms: ["lait"], excluding: [])
    #expect(first == b.suggestions(forms: ["lait"], excluding: []))
    #expect(first.map(\.id) == ["lait", "laitue"])
  }

  @Test func storeFailureMessageIsActionable() {
    let message = StoreFailureView.message(for: PersistenceError.appGroupUnavailable("group.x"))
    #expect(message.contains("group.x"))
    #expect(message.contains("Signing & Capabilities"))
    #expect(StoreFailureView.message(for: RepositoryError.visitClosed(UUID())).contains("Fermez l'app"))
  }

  @Test func failedAddKeepsTheInput() throws {
    let h = try Harness()
    let model = h.detail(UUID())
    model.input = "lait"
    model.submit()
    #expect(model.input == "lait")
    #expect(model.errorMessage != nil)
  }

  @Test func unknownCategoryJoinsOther() {
    let row = ItemRow(
      id: UUID(), label: "a", quantity: nil, categoryId: "disparue", normalizedName: "a", isChecked: false)
    let sections = ListDetailModel.group([row], categories: [("produce", "F"), ("other", "Autres")])
    #expect(sections.map(\.categoryId) == ["other"])
    // Même sans catégorie `other` en base, l'article reste visible.
    #expect(ListDetailModel.group([row], categories: []).map(\.title) == ["Autres"])
  }

  @Test func suggestionsComeFromHistoryAndCatalog() throws {
    let h = try Harness()
    let past = try h.lists.createList(name: "Avant", at: t0).id
    let product = Product(id: UUID(), name: "Tofu fumé", normalizedName: "tofu fume", categoryId: "world-food")
    h.context.insert(product)
    try h.context.save()
    let id = try h.lists.createList(name: "L", at: t0).id
    let old = h.detail(past)
    for text in ["Tomates", "tomates", "pommes de terre"] {
      old.input = text
      old.submit()
    }

    let model = h.detail(id)
    model.input = ""
    #expect(model.suggestions.isEmpty)
    model.input = "3 to"
    #expect(model.suggestions.map(\.normalizedName) == ["tomate", "tofu fume"])
    // Recherche sur n'importe quel mot, et au pluriel.
    model.input = "terres"
    #expect(model.suggestions.map(\.normalizedName) == ["pomme terre"])

    model.input = "3 to"
    model.add(try #require(model.suggestions.first))
    #expect(model.input.isEmpty)
    let row = model.sections[0].items[0]
    #expect(row.quantity == "3")
    #expect(row.label == "tomates")

    // Déjà à acheter : plus proposé. Le produit garde son identifiant et sa catégorie.
    model.input = "to"
    #expect(model.suggestions.map(\.normalizedName) == ["tofu fume"])
    model.add(try #require(model.suggestions.first))
    let added = try #require(try h.lists.items(listId: id).last)
    #expect(added.productId == product.id)
    #expect(added.categoryId == "world-food")
  }

  @Test func orphanItemsLeaveTheHistory() throws {
    let h = try Harness()
    h.context.insert(ListItem(listId: UUID(), label: "lait", normalizedName: "lait", categoryId: "dairy", position: 0))
    try h.context.save()
    #expect(try h.lists.itemHistory().isEmpty)
  }

  @Test func deletedListsLeaveTheHistory() throws {
    let h = try Harness()
    let gone = try h.lists.createList(name: "Avant", at: t0).id
    try h.lists.addItem(
      listId: gone, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    try h.lists.deleteList(id: gone, at: t0)
    #expect(try h.lists.itemHistory().isEmpty)
  }
}

/// Perte de session sur l'écran Liste : l'écran suit la liste, et la saisie n'est pas perdue.
@MainActor
@Suite struct ListDetailRekeyTests {
  @Test func theOpenListFollowsItsNewIdentifier() throws {
    let harness = try Harness()
    let list = try harness.lists.createList(name: "Courses", at: t0)
    let oldId = list.id
    let model = harness.detail(oldId)
    model.input = "lait"

    let remap = try AccountRekey.run(in: harness.context, now: t0)
    NotificationCenter.default.post(
      name: .syncDidRekeyData, object: nil, userInfo: [IdentifierRemap.userInfoKey: remap])

    model.load()
    #expect(!model.isMissing)
    #expect(model.input == "lait")
    #expect(model.listId == remap[oldId])
    model.submit()
    #expect(try harness.lists.items(listId: remap[oldId]).map(\.label) == ["lait"])
    #expect(try harness.context.fetch(FetchDescriptor<ListItem>()).count == 1)
  }
}
