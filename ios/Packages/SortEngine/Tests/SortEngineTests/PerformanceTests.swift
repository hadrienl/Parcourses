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
    let clock = ContinuousClock()
    let runs = 20
    var result: SortOutput?
    let elapsed = try clock.measure {
      for _ in 0..<runs { result = try sortItems(vector.input) }
    }
    #expect(result == vector.expected)
    let perRun = elapsed / runs
    print("SortEngine \(vector.id) : \(perRun) par tri")
    #expect(perRun < .milliseconds(20))
  }
}
