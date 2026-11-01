import XCTest

// XCTestCase est nonisolated : on sort de l'isolation MainActor par défaut.
nonisolated final class ParcoursesUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launch(reset: Bool) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests"
    if reset { app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1" }
    app.launch()
    return app
  }

  /// Capture conservée dans le `.xcresult`, sert de preuve visuelle aux PR.
  @MainActor
  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Parcours complet : créer, ajouter, voir groupé, cocher, supprimer, relancer et tout retrouver.
  @MainActor
  func testListJourneySurvivesRelaunch() {
    var app = launch(reset: true)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    capture(app, "1-listes-vide")

    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.typeText("Semaine")
    app.alerts.buttons["Créer"].tap()

    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    for text in ["2 laits demi-écrémé", "tomates", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      entry.typeText(text + "\n")
    }

    XCTAssertTrue(app.buttons["laits demi-écrémé, 2, non coché"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Fruits et légumes"].exists)
    XCTAssertTrue(app.staticTexts["Crèmerie, œufs, ultra-frais"].exists)

    capture(app, "2-liste-groupee")

    app.buttons["tomates, non coché"].tap()
    XCTAssertTrue(app.buttons["tomates, coché"].waitForExistence(timeout: 5))

    app.buttons["xyzzy, non coché"].swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    XCTAssertTrue(app.buttons["xyzzy, non coché"].waitForNonExistence(timeout: 5))

    // L'autocomplétion retrouve un article coché.
    entry.tap()
    entry.typeText("3 tom")
    let chip = app.buttons["Ajouter tomates"]
    XCTAssertTrue(chip.waitForExistence(timeout: 5))
    capture(app, "3-autocompletion")
    chip.tap()
    XCTAssertTrue(app.buttons["tomates, 3, non coché"].waitForExistence(timeout: 5))

    app.terminate()
    app = launch(reset: false)
    let list = app.staticTexts["Semaine"]
    XCTAssertTrue(list.waitForExistence(timeout: 15))
    list.tap()
    XCTAssertTrue(app.buttons["laits demi-écrémé, 2, non coché"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["tomates, coché"].exists)
    XCTAssertTrue(app.buttons["tomates, 3, non coché"].exists)
    XCTAssertFalse(app.buttons["xyzzy, non coché"].exists)
    capture(app, "4-apres-relance")

    // Retour à l'écran Listes, suppression de la liste, toujours supprimée après relance.
    app.navigationBars.buttons.firstMatch.tap()
    let row = app.buttons.containing(.staticText, identifier: "Semaine").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5))
    capture(app, "5-mes-listes")
    row.swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    let confirm = app.buttons["Supprimer la liste"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 5))
  }
}
