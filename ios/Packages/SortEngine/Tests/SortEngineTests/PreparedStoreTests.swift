import Testing

@testable import SortEngine

/// #30 : le magasin préparé accélère le tri sans jamais en changer le résultat.
@Suite("Magasin préparé")
struct PreparedStoreTests {
  /// Une visite entière avec le même magasin préparé : chaque recalcul réutilise les distances
  /// déjà calculées et doit rester identique au tri sans précalcul.
  @Test(
    "Une visite avec un seul magasin préparé donne le tri sans précalcul",
    arguments: ["031", "032", "magasin-400"])
  func visitWithOneStoreMatchesPlainSort(_ name: String) throws {
    let input =
      name == "magasin-400"
      ? SyntheticStore.input(products: SyntheticStore.storeProducts) : SortVector.named(name).input
    let prepared = try PreparedStore(snapshot: try #require(input.snapshot), params: input.params)
    #expect(prepared.matches(input))
    var current = input
    // 30 coches suffisent à exercer le cache ; la liste vide et l'article seul ont leurs vecteurs
    // (029, 030). Le tri sans précalcul est lent en debug.
    for _ in 0..<30 where !current.items.isEmpty {
      let plain = try sortItems(current)
      #expect(try sortItems(current, prepared: prepared) == plain)
      // On coche le premier article : départ depuis son produit, ordre précédent conservé.
      let checked = try #require(current.items.first { $0.id == plain.order.first })
      current.items.removeAll { $0.id == checked.id }
      if let productId = checked.productId { current.start = .product(productId) }
      current.previousOrder = Array(plain.order.dropFirst())
    }
  }

  /// Le second tri identique ne calcule aucune nouvelle ligne : le cache sert bien.
  @Test func distancesAreComputedOnce() throws {
    let input = SyntheticStore.input(products: SyntheticStore.storeProducts)
    let prepared = try PreparedStore(snapshot: try #require(input.snapshot), params: input.params)
    #expect(prepared.cachedSources == 0)
    let first = try sortItems(input, prepared: prepared)
    // L'entrée et les 80 produits de la liste.
    #expect(prepared.cachedSources == SyntheticStore.items + 1)
    #expect(try sortItems(input, prepared: prepared) == first)
    #expect(prepared.cachedSources == SyntheticStore.items + 1)
  }

  @Test func storeOfAnotherSnapshotIsIgnored() throws {
    let input = SortVector.named("031").input
    let other = SortVector.named("033").input
    let prepared = try PreparedStore(snapshot: try #require(other.snapshot), params: other.params)
    #expect(!prepared.matches(input))
    #expect(try sortItems(input, prepared: prepared) == sortItems(input))
  }

  @Test func storeWithOtherParamsIsIgnored() throws {
    let input = SortVector.named("031").input
    var params = input.params
    params.costScale = 7
    let prepared = try PreparedStore(snapshot: try #require(input.snapshot), params: params)
    #expect(!prepared.matches(input))
    var sameParams = input
    sameParams.params = params
    #expect(prepared.matches(sameParams))
    #expect(try sortItems(input, prepared: prepared) == sortItems(input))
  }

  @Test func invalidSnapshotIsRejectedLikeSortItems() {
    let snapshot = SortSnapshot(
      confidenceQ: 900, entries: [], edges: [SnapshotEdge(a: "p-1", b: "P-2", weightQ: 1)])
    var input = SyntheticStore.input(products: SyntheticStore.items)
    input.snapshot = snapshot
    let expected = SortError.invalidId(field: "edge.b", value: "P-2")
    #expect(throws: expected) { try sortItems(input) }
    #expect(throws: expected) { try PreparedStore(snapshot: snapshot, params: input.params) }
  }

  /// Le reste de l'entrée est toujours validé, même quand l'instantané l'a été à la préparation.
  @Test func requestIsStillValidated() throws {
    var input = SyntheticStore.input(products: SyntheticStore.items)
    let prepared = try PreparedStore(snapshot: try #require(input.snapshot), params: input.params)
    input.previousOrder = ["I-1"]
    #expect(throws: SortError.invalidId(field: "previous_order", value: "I-1")) {
      try sortItems(input, prepared: prepared)
    }
  }
}
