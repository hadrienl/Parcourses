import XCTest

final class ParcoursesUITests: XCTestCase {
  @MainActor
  func testLaunchShowsRoot() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
  }
}
