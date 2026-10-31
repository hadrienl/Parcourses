import XCTest

// XCTestCase est nonisolated : on sort de l'isolation MainActor par défaut.
nonisolated final class ParcoursesUITests: XCTestCase {
  @MainActor
  func testLaunchShowsRoot() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }
}
