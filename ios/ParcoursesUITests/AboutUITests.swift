import XCTest

/// Écran À propos (#87, lot 87.8) : lien vers la politique de confidentialité, et textes qui suivent la nature du
/// compte. Avec serveur, le compte vient de `UITestSharingGateway` (`owner` : e-mail, `anonymous` : anonyme).
nonisolated final class AboutUITests: ParcoursesUITestCase {
  private static let anonymousRetention =
    "Vous pouvez supprimer ces données à tout moment ci-dessous. Sur nos serveurs, elles sont aussi supprimées après 365 jours sans utilisation de l'app."
  private static let sharedListsSentence = "Une liste que vous partagez avec d'autres passe à l'un de ses membres."

  /// Build sans serveur : le lien est là, sans phrase sur la purge.
  @MainActor
  func testPrivacyPolicyLinkWithoutServer() {
    let app = launch(reset: true, launchArguments: AccountDeletionUITests.localOnly)
    openAbout(app)
    let link = policyLink(app)
    reveal(link, in: app)
    XCTAssertEqual(link.label, "Politique de confidentialité")
    XCTAssertGreaterThanOrEqual(link.frame.height, 44)
    XCTAssertFalse(app.staticTexts["aboutRetention"].exists)
    capture(app, "a-propos-sans-serveur")
  }

  @MainActor
  func testEmailAccountIsNeverPurgedForInactivity() {
    let app = launchWithServer("owner")
    openAbout(app)
    XCTAssertTrue(policyLink(app).waitForExistence(timeout: 15))
    let retention = app.staticTexts["aboutRetention"]
    reveal(retention, in: app)
    XCTAssertEqual(retention.label, "Vous pouvez supprimer ces données à tout moment ci-dessous.")
    let yourData = app.staticTexts["aboutYourData"]
    reveal(yourData, in: app)
    XCTAssertEqual(
      yourData.label,
      "Vous pouvez effacer vos listes, vos visites et votre compte (adresse e-mail et prénom), sur cet appareil et sur nos serveurs."
    )
    capture(app, "a-propos-compte-email")
    let confirmation = openConfirmation(app)
    XCTAssertTrue(
      confirmation.staticTexts[
        "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que votre compte (adresse e-mail et prénom). \(Self.sharedListsSentence) Votre contribution anonyme au plan des rayons des magasins est conservée. C'est définitif."
      ].exists)
    capture(app, "a-propos-compte-email-confirmation")
    confirmation.buttons["Annuler"].firstMatch.tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 15))
  }

  @MainActor
  func testAnonymousAccountMentionsThePurge() {
    let app = launchWithServer("anonymous")
    openAbout(app)
    XCTAssertTrue(policyLink(app).waitForExistence(timeout: 15))
    let retention = app.staticTexts["aboutRetention"]
    reveal(retention, in: app)
    XCTAssertEqual(retention.label, Self.anonymousRetention)
    let yourData = app.staticTexts["aboutYourData"]
    reveal(yourData, in: app)
    XCTAssertEqual(
      yourData.label,
      "Vous pouvez effacer vos listes, vos visites et votre identifiant anonyme, sur cet appareil et sur nos serveurs.")
    capture(app, "a-propos-compte-anonyme")
    let confirmation = openConfirmation(app)
    XCTAssertTrue(
      confirmation.staticTexts[
        "Vos listes, vos visites et vos articles cochés seront effacés de cet appareil et de nos serveurs, ainsi que votre identifiant anonyme. \(Self.sharedListsSentence) Votre contribution anonyme au plan des rayons des magasins est conservée. C'est définitif."
      ].exists)
    confirmation.buttons["Annuler"].firstMatch.tap()
    XCTAssertTrue(confirmation.waitForNonExistence(timeout: 15))
  }

  /// Serveur en mémoire de `UITestSharingGateway`, sur un store à part.
  @MainActor
  private func launchWithServer(_ scenario: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_SHARING"] = scenario
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-about"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    app.launch()
    return app
  }

  /// Un `Link` SwiftUI est un lien pour XCUITest, ou un bouton selon la version d'iOS : cherché quel que soit son type.
  @MainActor
  private func policyLink(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["aboutPrivacyPolicyLink"]
  }

  @MainActor
  private func openAbout(_ app: XCUIApplication) {
    let about = app.buttons["about"]
    XCTAssertTrue(about.waitForExistence(timeout: 15))
    about.tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForExistence(timeout: 15))
  }

  /// « Supprimer mes données… » depuis l'écran À propos ouvert : renvoie l'alerte de confirmation.
  @MainActor
  private func openConfirmation(_ app: XCUIApplication) -> XCUIElement {
    let button = app.buttons["deleteMyData"]
    reveal(button, in: app)
    button.tap()
    let confirmation = app.alerts["Supprimer toutes vos données ?"]
    XCTAssertTrue(confirmation.waitForExistence(timeout: 15))
    return confirmation
  }
}
