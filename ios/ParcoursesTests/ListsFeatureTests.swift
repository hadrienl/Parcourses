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

  func detail(_ id: UUID) -> ListDetailModel { environment.makeListDetailModel(listId: id) }
}

@MainActor
@Suite struct ListsModelTests {
  @Test func createRenameDeleteAndCounts() throws {
    let h = try Harness()
    let model = h.environment.makeListsModel()
    model.load()
    #expect(model.lists.isEmpty)
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
    #expect(model.errorMessage != nil)
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
    #expect(model.sections[1].title == "Crèmerie, œufs, ultra-frais")
    let milk = model.sections[1].items[0]
    #expect(milk.label == "laits demi-écrémé")
    #expect(milk.quantity == "2")
    #expect(milk.accessibilityLabel == "laits demi-écrémé, 2, non coché")
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
    #expect(model.sections[0].items[0].accessibilityLabel == "tomates, coché")

    model.toggle(model.sections[0].items[0])
    #expect(try h.lists.items(listId: id)[0].checkedAt == nil)

    model.delete(model.sections[0].items[0])
    #expect(try h.lists.items(listId: id).isEmpty)
    #expect(model.isEmpty)
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

  @Test func deletedListsLeaveTheHistory() throws {
    let h = try Harness()
    let gone = try h.lists.createList(name: "Avant", at: t0).id
    try h.lists.addItem(
      listId: gone, label: "lait", normalizedName: "lait", quantity: nil, productId: nil, categoryId: "dairy", at: t0)
    try h.lists.deleteList(id: gone, at: t0)
    #expect(try h.lists.itemHistory().isEmpty)
  }
}
