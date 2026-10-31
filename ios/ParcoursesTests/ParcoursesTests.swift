import Testing

@testable import Parcourses

@MainActor
@Test func appGroupIsConfigured() {
  #expect(AppGroup.identifier == "group.app.parcourses")
}
