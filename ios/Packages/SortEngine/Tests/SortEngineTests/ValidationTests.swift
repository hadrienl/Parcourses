import Foundation
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
    #expect(throws: SortError.invalidWeight(context: "p-1-p-2", weightQ: -1)) {
      try sortItems(input(snapshot: edge))
    }
    let entry = SortSnapshot(confidenceQ: 900, entries: [SnapshotEntry(productId: "p-1", weightQ: -5)], edges: [])
    #expect(throws: SortError.invalidWeight(context: "entry p-1", weightQ: -5)) {
      try sortItems(input(snapshot: entry))
    }
  }

  @Test("Poids au-delà de 2^53-1 refusés, sans débordement", arguments: [Int64(1) << 53, Int64.max])
  func rejectsUnsafeWeights(_ weightQ: Int64) {
    let edge = SortSnapshot(confidenceQ: 900, entries: [], edges: [SnapshotEdge(a: "p-1", b: "p-2", weightQ: weightQ)])
    #expect(throws: SortError.invalidWeight(context: "p-1-p-2", weightQ: weightQ)) {
      try sortItems(input(snapshot: edge))
    }
    let entry = SortSnapshot(confidenceQ: 900, entries: [SnapshotEntry(productId: "p-1", weightQ: weightQ)], edges: [])
    #expect(throws: SortError.invalidWeight(context: "entry p-1", weightQ: weightQ)) {
      try sortItems(input(snapshot: entry))
    }
  }

  @Test func acceptsLargestSafeWeight() throws {
    let weightQ: Int64 = (1 << 53) - 1
    let snapshot = SortSnapshot(
      confidenceQ: 900, entries: [SnapshotEntry(productId: "p-1", weightQ: weightQ)],
      edges: [SnapshotEdge(a: "p-1", b: "p-2", weightQ: weightQ)])
    #expect(try sortItems(input(snapshot: snapshot)).mode == .learned)
  }

  @Test func fallbackComparesNFCAndNFDAsDifferentBytes() throws {
    // Même texte pour `String` : NFC commence par C3, NFD par 65, donc NFD passe d'abord malgré
    // l'identifiant. Avec l'égalité de `String`, le départage par identifiant inverserait l'ordre.
    let nfc = "\u{E9}"
    let nfd = "e\u{301}"
    #expect(nfc == nfd)
    #expect(compareBytes(nfd, nfc) < 0)
    let items = [
      SortItem(id: "i-a", productId: nil, categoryId: "dairy", normalizedName: nfc),
      SortItem(id: "i-b", productId: nil, categoryId: "dairy", normalizedName: nfd),
    ]
    #expect(try sortItems(input(items: items)).order == ["i-b", "i-a"])
  }

  @Test("Décodage de start : entry d'abord, comme la référence")
  func decodesStart() throws {
    func decode(_ json: String) throws -> SortStart {
      try JSONDecoder().decode(SortStart.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"entry":true}"#) == .entry)
    #expect(try decode(#"{"entry":false}"#) == .entry)
    #expect(try decode(#"{"entry":true,"product_id":"p-1"}"#) == .entry)
    #expect(try decode(#"{"product_id":"p-1"}"#) == .product("p-1"))
    #expect(throws: DecodingError.self) { try decode("{}") }
  }

  @Test func comparesBytesNotUnicode() {
    // « é » (C3 A9) passe après « z » (7A) en octets UTF-8.
    #expect(compareBytes("z", "é") < 0)
    #expect(compareBytes("ab", "abc") < 0)
    #expect(compareBytes("abc", "abc") == 0)
  }
}
