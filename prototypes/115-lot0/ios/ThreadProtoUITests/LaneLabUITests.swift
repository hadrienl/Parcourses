import XCTest

// Gestes du couloir (#115, lot 0) : toucher, glisser maison, menu contextuel, défilement, geste retour, RTL.
// Les captures sont écrites dans `$PROTO_SHOTS` (passé par `TEST_RUNNER_PROTO_SHOTS`).
final class LaneLabUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = true
  }

  private func launch(rtl: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-scenario", "lane"] + (rtl ? ["-rtl", "1"] : [])
    app.launch()
    return app
  }

  private func shot(_ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["PROTO_SHOTS"] else { return }
    let data = XCUIScreen.main.screenshot().pngRepresentation
    try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
  }

  private func status(_ app: XCUIApplication) -> String {
    app.staticTexts["status"].label
  }

  func testLaneGestures() {
    let app = launch()
    let lane3 = app.buttons["lane-3"]
    XCTAssertTrue(lane3.waitForExistence(timeout: 10))
    shot("lane-rest")
    XCTAssertFalse(app.buttons["Supprimer"].exists, "le bouton n'existe que ligne ouverte")

    // Toucher : l'action du Button passe malgré le pan.
    lane3.tap()
    XCTAssertEqual(status(app), "tap 3")

    // Glisser court et rapide (comme les tests de l'app) : la ligne s'ouvre.
    lane3.swipeLeft()
    let delete = app.buttons["Supprimer"]
    XCTAssertTrue(delete.waitForExistence(timeout: 2), "swipeLeft ouvre la ligne")
    shot("lane-open")
    XCTAssertEqual(app.buttons.matching(identifier: "Supprimer").count, 1)
    delete.tap()
    XCTAssertTrue(app.staticTexts["delete 3"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.buttons["lane-3"].exists)

    // Glisser lent, tenu : capture pendant le geste (le fil ne doit pas avoir bougé).
    let lane5 = app.buttons["lane-5"]
    lane5.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(
      forDuration: 0.05,
      thenDragTo: lane5.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)),
      withVelocity: .slow,
      thenHoldForDuration: 0.5)
    shot("lane-after-slow-drag")
    // Un toucher ailleurs referme.
    app.buttons["lane-7"].tap()

    // Appui long : menu contextuel, aperçu = couloir seul.
    let lane6 = app.buttons["lane-6"]
    lane6.press(forDuration: 1.2)
    let notFound = app.buttons["Pas trouvé"]
    XCTAssertTrue(notFound.waitForExistence(timeout: 3), "menu contextuel ouvert")
    shot("lane-menu")
    notFound.tap()
    XCTAssertTrue(app.staticTexts["notFound 6"].waitForExistence(timeout: 2))

    // Défilement vertical : le pan ne le gêne pas.
    let firstFrame = app.buttons["lane-0"].frame
    app.buttons["lane-8"].swipeUp()
    XCTAssertNotEqual(app.buttons["lane-0"].frame.minY, firstFrame.minY, "la liste défile")
    XCTAssertFalse(app.buttons["Supprimer"].exists, "pas de ligne ouverte par un défilement")
    app.buttons["lane-10"].swipeDown()

    // Action d'accessibilité « Supprimer » sur le couloir.
    XCTAssertTrue(app.buttons["lane-4"].exists)

    // Geste retour du bord d'écran : il garde la priorité.
    let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
    edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    XCTAssertTrue(app.buttons["Ouvrir le couloir"].waitForExistence(timeout: 3), "retour à la racine")
  }

  func testLaneRightToLeft() {
    let app = launch(rtl: true)
    let lane3 = app.buttons["lane-3"]
    XCTAssertTrue(lane3.waitForExistence(timeout: 10))
    shot("rtl-rest")
    lane3.swipeRight()
    XCTAssertTrue(app.buttons["Supprimer"].waitForExistence(timeout: 2), "swipeRight ouvre la ligne en RTL")
    shot("rtl-open")
  }
}
