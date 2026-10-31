import Testing

@testable import SortEngine

@Suite("Validation des entrées")
struct ValidationTests {
  private func input(
    categories: [SortCategory] = [SortCategory(id: "dairy", rank: 10)],
    snapshot: SortSnapshot? = nil,
    items: [SortItem] = [SortItem(id: "i-1", productId: "p-1", categoryId: "dairy", normalizedName: "lait")],
    start: SortStart = .entry,
    previousOrder: [String]? = nil
  ) -> SortInput {
    SortInput(
      categories: categories, snapshot: snapshot, items: items, start: start, previousOrder: previousOrder)
  }

  @Test func acceptsValidInput() throws {
    #expect(try sortItems(input()).mode == .fallback)
  }

  @Test("Identifiants hors de [0-9a-z-]+", arguments: ["", "I-1", "i_1", "i 1", "é", "i-1\n"])
  func rejectsInvalidItemId(_ id: String) {
    let items = [SortItem(id: id, productId: nil, categoryId: nil, normalizedName: "x")]
    #expect(throws: SortError.invalidId(field: "item", value: id)) { try sortItems(input(items: items)) }
  }

  @Test func rejectsInvalidIdsEverywhere() {
    let bad = "Bad"
    #expect(throws: SortError.self) { try sortItems(input(categories: [SortCategory(id: bad, rank: 1)])) }
    #expect(throws: SortError.self) {
      try sortItems(input(items: [SortItem(id: "i", productId: bad, categoryId: nil, normalizedName: "")]))
    }
    #expect(throws: SortError.self) {
      try sortItems(input(items: [SortItem(id: "i", productId: nil, categoryId: bad, normalizedName: "")]))
    }
    #expect(throws: SortError.self) { try sortItems(input(start: .product(bad))) }
    #expect(throws: SortError.self) { try sortItems(input(previousOrder: [bad])) }
    let edge = SortSnapshot(confidenceQ: 900, entries: [], edges: [SnapshotEdge(a: "p-1", b: bad, weightQ: 1)])
    #expect(throws: SortError.self) { try sortItems(input(snapshot: edge)) }
    let entry = SortSnapshot(confidenceQ: 900, entries: [SnapshotEntry(productId: bad, weightQ: 1)], edges: [])
    #expect(throws: SortError.self) { try sortItems(input(snapshot: entry)) }
  }

  @Test func rejectsDuplicates() {
    let category = SortCategory(id: "dairy", rank: 10)
    #expect(throws: SortError.duplicateCategory("dairy")) {
      try sortItems(input(categories: [category, category]))
    }
    let item = SortItem(id: "i-1", productId: nil, categoryId: nil, normalizedName: "x")
    #expect(throws: SortError.duplicateItem("i-1")) { try sortItems(input(items: [item, item])) }
  }

  @Test func rejectsNegativeWeights() {
    let edge = SortSnapshot(confidenceQ: 900, entries: [], edges: [SnapshotEdge(a: "p-1", b: "p-2", weightQ: -1)])
    #expect(throws: SortError.negativeWeight(context: "p-1-p-2", weightQ: -1)) {
      try sortItems(input(snapshot: edge))
    }
    let entry = SortSnapshot(confidenceQ: 900, entries: [SnapshotEntry(productId: "p-1", weightQ: -5)], edges: [])
    #expect(throws: SortError.negativeWeight(context: "entry p-1", weightQ: -5)) {
      try sortItems(input(snapshot: entry))
    }
  }

  @Test func comparesBytesNotUnicode() {
    // « é » (C3 A9) passe après « z » (7A) en octets UTF-8.
    #expect(compareBytes("z", "é") < 0)
    #expect(compareBytes("ab", "abc") < 0)
    #expect(compareBytes("abc", "abc") == 0)
  }
}
