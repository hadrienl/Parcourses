import XCTest

/// « Supprimer mes données… » (#68 §5.1, §5.2), lancée sans passerelle : la suppression ne purge que l'appareil
/// (§5.7), avec les mêmes écrans.
nonisolated final class AccountDeletionUITests: ParcoursesUITestCase {
  /// `AuthBootstrap.localOnlyArgument` : sans passerelle, même avec `Local.xcconfig`.
  static let localOnly = ["PARCOURSES_TEST_LOCAL_ONLY"]

  @MainActor
  func testCancelKeepsEverythingAndDeleteEmptiesTheLists() {
    let app = launch(reset: true, launchArguments: Self.localOnly)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.typeText("Semaine")
    app.alerts.buttons["Créer"].tap()
    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    entry.tap()
    entry.typeText("tomates\n")
    XCTAssertTrue(row(app, "tomates", "non coché").waitForExistence(timeout: 5))
    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Semaine"].waitForExistence(timeout: 5))

    // Annuler ne touche à rien.
    let confirmation = openConfirmation(app)
    capture(app, "suppression-1-confirmation")
    confirmation.buttons["Annuler"].firstMatch.tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
    app.buttons["closeAbout"].tap()
    XCTAssertTrue(app.staticTexts["Semaine"].waitForExistence(timeout: 5))

    // Supprimer : message, puis l'écran Listes vide.
    openConfirmation(app).buttons["Supprimer"].firstMatch.tap()
    let done = app.alerts["Vos données ont été supprimées."]
    XCTAssertTrue(done.waitForExistence(timeout: 15))
    capture(app, "suppression-2-terminee")
    done.buttons["OK"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["Semaine"].exists)
    capture(app, "suppression-3-listes-vides")

    // Rien ne revient après une relance.
    app.terminate()
    let relaunched = launch(reset: false, launchArguments: Self.localOnly)
    XCTAssertTrue(relaunched.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
  }

  /// Libellés lus par VoiceOver : section, bouton et son indice, confirmation et ses boutons.
  @MainActor
  func testVoiceOverLabels() {
    let app = launch(reset: true, launchArguments: Self.localOnly)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    openAbout(app)
    let button = app.buttons["deleteMyData"]
    reveal(button, in: app)
    XCTAssertEqual(button.label, "Supprimer mes données…")
    XCTAssertTrue(app.staticTexts["VOS DONNÉES"].exists || app.staticTexts["Vos données"].exists)
    XCTAssertTrue(app.staticTexts["Vous pouvez effacer vos listes et vos visites de cet appareil."].exists)
    XCTAssertGreaterThanOrEqual(button.frame.height, 44)
    button.tap()
    let confirmation = app.alerts["Supprimer toutes vos données ?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    XCTAssertTrue(confirmation.staticTexts["Vos listes et vos visites seront effacées de cet appareil."].exists)
    XCTAssertTrue(confirmation.buttons["Supprimer"].firstMatch.exists)
    XCTAssertTrue(confirmation.buttons["Annuler"].firstMatch.exists)
    confirmation.buttons["Annuler"].firstMatch.tap()
  }

  @MainActor
  private func openAbout(_ app: XCUIApplication) {
    let about = app.buttons["about"]
    XCTAssertTrue(about.waitForExistence(timeout: 5))
    about.tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForExistence(timeout: 5))
  }

  /// À propos, puis « Supprimer mes données… » : renvoie l'alerte de confirmation.
  @MainActor
  @discardableResult
  private func openConfirmation(_ app: XCUIApplication) -> XCUIElement {
    openAbout(app)
    let button = app.buttons["deleteMyData"]
    reveal(button, in: app)
    button.tap()
    let confirmation = app.alerts["Supprimer toutes vos données ?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    return confirmation
  }
}
