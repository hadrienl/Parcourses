import Testing

@testable import SortEngine

#if DEBUG
  private let isReleaseBuild = false
#else
  private let isReleaseBuild = true
#endif

@Suite("Performance")
struct PerformanceTests {
  /// #9 §3.3 : n ≤ 80 en moins de 5 ms. Le seuil de 20 ms laisse de la marge à la CI partagée.
  /// Mesure en release seulement (le debug est ~20 fois plus lent) : la CI lance
  /// `swift test -c release --filter PerformanceTests`.
  @Test("80 articles", .enabled(if: isReleaseBuild), arguments: ["031", "032"])
  func eightyItems(_ prefix: String) throws {
    let vector = SortVector.named(prefix)
    #expect(vector.input.items.count == 80)
    let result = try measureWithinBudget(vector.id) { try sortItems(vector.input) }
    #expect(result == vector.expected)
  }

  /// Graphe dense : presque toutes les paires des 80 produits de la liste sont reliées.
  @Test("Graphe dense de 80 produits", .enabled(if: isReleaseBuild))
  func denseGraph() throws {
    let input = SyntheticStore.input(products: SyntheticStore.items)
    try expectSyntheticOutput(input, cost: 13_683, head: ["i-7", "i-78", "i-13", "i-76", "i-58"])
    _ = try measureWithinBudget("dense-80-produits") { try sortItems(input) }
  }

  /// #30 : magasin de 400 produits, 3 000 arêtes, 80 articles. Premier tri d'une visite, sans
  /// précalcul : les Dijkstra parcourent aussi les produits absents de la liste.
  @Test("Magasin de 400 produits, premier tri", .enabled(if: isReleaseBuild))
  func largeStoreFirstSort() throws {
    let input = SyntheticStore.input(products: SyntheticStore.storeProducts)
    try expectSyntheticOutput(input, cost: 22_848, head: ["i-13", "i-57", "i-70", "i-49", "i-17"])
    _ = try measureWithinBudget("magasin-400-produits, premier tri") { try sortItems(input) }
  }

  /// #30 : recalcul après une coche avec le magasin préparé ; les distances viennent du cache.
  @Test("Magasin de 400 produits, recalcul préparé", .enabled(if: isReleaseBuild))
  func largeStoreRecompute() throws {
    let input = SyntheticStore.input(products: SyntheticStore.storeProducts)
    let prepared = try PreparedStore(snapshot: try #require(input.snapshot), params: input.params)
    let first = try sortItems(input, prepared: prepared)
    let checked = try #require(input.items.first { $0.id == first.order.first })
    var recompute = input
    recompute.items.removeAll { $0.id == checked.id }
    recompute.start = .product(try #require(checked.productId))
    recompute.previousOrder = Array(first.order.dropFirst())
    let result = try measureWithinBudget("magasin-400-produits, recalcul préparé") {
      try sortItems(recompute, prepared: prepared)
    }
    #expect(result == (try sortItems(recompute)))
  }

  /// Même coût et même début d'ordre qu'Android (`SortPerformanceTest.kt`) sur le même graphe.
  private func expectSyntheticOutput(_ input: SortInput, cost: Int64, head: [String]) throws {
    #expect(input.snapshot?.edges.count == SyntheticStore.edges)
    let output = try sortItems(input)
    #expect(output.mode == .learned)
    #expect(output.order.sorted() == input.items.map(\.id).sorted())
    #expect(output.cost == cost)
    #expect(Array(output.order.prefix(head.count)) == head)
  }

  /// Durée moyenne de 20 tris sous 20 ms ; renvoie le dernier résultat.
  private func measureWithinBudget(
    _ name: String, _ sort: () throws -> SortOutput
  ) throws -> SortOutput? {
    let clock = ContinuousClock()
    let runs = 20
    var result: SortOutput?
    let elapsed = try clock.measure {
      for _ in 0..<runs { result = try sort() }
    }
    let perRun = elapsed / runs
    print("SortEngine \(name) : \(perRun) par tri")
    #expect(perRun < .milliseconds(20))
    return result
  }
}
