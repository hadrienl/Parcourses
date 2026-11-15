import XCTest

/// Bouton compte de Mes listes et écran Compte (#108), sur le serveur en mémoire de `UITestSharingGateway`. Les
/// captures (`compte-…`) servent à la PR (`xcrun xcresulttool export attachments`).
nonisolated final class AccountScreenUITests: ParcoursesUITestCase {
  @MainActor
  private func launch(_ scenario: String, dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_SHARING"] = scenario
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-sharing"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
    if largeText {
      app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    }
    app.launch()
    return app
  }

  @MainActor
  private func waitForLists(_ app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Courses de la semaine")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
  }

  @MainActor
  private func openAccount(_ app: XCUIApplication) {
    let account = app.buttons["account"]
    XCTAssertTrue(account.waitForExistence(timeout: 15))
    account.tap()
    XCTAssertTrue(app.navigationBars["Compte"].waitForExistence(timeout: 15))
  }

  // MARK: - Compte e-mail

  /// La pastille reste une fois connecté, porte le prénom dans son libellé lu, et ouvre l'écran Compte.
  @MainActor
  func testSignedInButtonOpensAccount() {
    runAccount(dark: false, largeText: false)
  }

  @MainActor
  func testAccountDark() {
    runAccount(dark: true, largeText: false)
  }

  @MainActor
  func testAccountWithLargeText() {
    runAccount(dark: false, largeText: true)
  }

  @MainActor
  private func runAccount(dark: Bool, largeText: Bool) {
    let app = launch("owner", dark: dark, largeText: largeText)
    let name = (dark ? "-sombre" : "-clair") + (largeText ? "-texte-agrandi" : "")
    waitForLists(app)
    let account = app.buttons["account"]
    XCTAssertTrue(account.waitForExistence(timeout: 15))
    // Le prénom est relu sur le serveur après le lancement.
    let named = NSPredicate(format: "label == %@", "Compte, Hadrien")
    expectation(for: named, evaluatedWith: account)
    waitForExpectations(timeout: 15)
    XCTAssertFalse(app.buttons["signIn"].exists)
    capture(app, "compte-1-mes-listes\(name)")

    openAccount(app)
    let email = app.descendants(matching: .any)["accountEmail"]
    XCTAssertTrue(email.waitForExistence(timeout: 10))
    XCTAssertTrue(email.label.contains("hadrien@exemple.fr"), email.label)
    XCTAssertTrue(app.buttons["accountName"].label.contains("Hadrien"), app.buttons["accountName"].label)
    XCTAssertTrue(app.buttons["signOut"].exists)
    capture(app, "compte-2-ecran\(name)")
    let delete = app.buttons["deleteMyData"]
    reveal(delete, in: app)
    XCTAssertTrue(delete.exists)
    capture(app, "compte-3-vos-donnees\(name)")
    app.buttons["closeAccount"].tap()
    XCTAssertTrue(app.navigationBars["Compte"].waitForNonExistence(timeout: 10))

    // À propos ne dit plus rien du compte, ni de la suppression : elle est dans Compte.
    app.buttons["about"].tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Données cartographiques"].waitForExistence(timeout: 5))
    capture(app, "compte-4-a-propos\(name)")
    // En texte agrandi, la version est loin sous le pli.
    reveal(app.staticTexts["Version"], in: app)
    capture(app, "compte-5-a-propos-bas\(name)")
    for identifier in ["accountEmail", "accountName", "signOut", "deleteMyData"] {
      XCTAssertFalse(app.descendants(matching: .any)[identifier].exists, identifier)
    }
  }

  /// Prénom modifié depuis l'écran Compte : la pastille et son libellé suivent.
  @MainActor
  func testEditNameFromAccount() {
    let app = launch("owner")
    waitForLists(app)
    openAccount(app)
    let nameRow = app.buttons["accountName"]
    XCTAssertTrue(nameRow.waitForExistence(timeout: 10))
    nameRow.tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    field.tap()
    if let current = field.value as? String, !current.isEmpty {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    type("Élodie", into: field, app)
    app.alerts.buttons["Enregistrer"].tap()
    XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 10))
    let updated = NSPredicate(format: "label CONTAINS %@", "Élodie")
    expectation(for: updated, evaluatedWith: nameRow)
    waitForExpectations(timeout: 15)
    app.buttons["closeAccount"].tap()
    let account = app.buttons["account"]
    expectation(for: NSPredicate(format: "label == %@", "Compte, Élodie"), evaluatedWith: account)
    waitForExpectations(timeout: 15)
  }

  /// « Se déconnecter » depuis l'écran Compte : confirmation, purge, puis compte anonyme et « Se connecter ».
  @MainActor
  func testSignOutFromAccount() {
    let app = launch("owner")
    waitForLists(app)
    openAccount(app)
    let signOut = app.buttons["signOut"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 10))
    signOut.tap()
    XCTAssertTrue(app.alerts["Se déconnecter ?"].waitForExistence(timeout: 10))
    capture(app, "compte-6-se-deconnecter")
    app.alerts.buttons["confirmSignOut"].tap()
    XCTAssertTrue(app.buttons["signIn"].waitForExistence(timeout: 30))
    XCTAssertFalse(app.buttons["account"].exists)
    XCTAssertFalse(app.navigationBars["Compte"].exists)
    capture(app, "compte-7-apres-deconnexion")
  }

  // MARK: - Compte anonyme

  /// Anonyme : « Se connecter » ouvre la connexion, et la suppression des données reste dans À propos.
  @MainActor
  func testAnonymousButtonOpensSignInAndAboutKeepsDeletion() {
    let app = launch("anonymous")
    let signIn = app.buttons["signIn"]
    XCTAssertTrue(signIn.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["account"].exists)
    capture(app, "compte-8-anonyme")

    app.buttons["about"].tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForExistence(timeout: 15))
    let delete = app.buttons["deleteMyData"]
    reveal(delete, in: app)
    XCTAssertTrue(delete.exists)
    XCTAssertFalse(app.descendants(matching: .any)["signOut"].exists)
    app.buttons["closeAbout"].tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForNonExistence(timeout: 10))

    signIn.tap()
    XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 15))
    XCTAssertFalse(app.navigationBars["Compte"].exists)
  }
}
