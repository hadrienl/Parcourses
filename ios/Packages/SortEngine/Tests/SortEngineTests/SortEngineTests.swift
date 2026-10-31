import Testing

@testable import SortEngine

@Test func moduleIsLinked() {
  #expect(SortEngine.version == "0.1.0")
}
