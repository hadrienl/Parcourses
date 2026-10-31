import Testing

@testable import Domain

@Test func moduleIsLinked() {
  #expect(Domain.version == "0.1.0")
}
