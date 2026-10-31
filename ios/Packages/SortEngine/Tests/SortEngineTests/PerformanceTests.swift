import Testing

@testable import SortEngine

@Suite("Performance")
struct PerformanceTests {
  /// #9 §3.3 : n ≤ 80 en moins de 5 ms. Le seuil est large (CI partagée, build debug) : il
  /// détecte une régression de complexité, pas une variation de quelques millisecondes.
  @Test("80 articles", arguments: ["031", "032"])
  func eightyItems(_ prefix: String) throws {
    let vector = SortVector.named(prefix)
    #expect(vector.input.items.count == 80)
    let clock = ContinuousClock()
    let runs = 20
    var result: SortOutput?
    let elapsed = try clock.measure {
      for _ in 0..<runs { result = try sortItems(vector.input) }
    }
    #expect(result == vector.expected)
    let perRun = elapsed / runs
    print("SortEngine \(vector.id) : \(perRun) par tri")
    #expect(perRun < .milliseconds(100))
  }
}
