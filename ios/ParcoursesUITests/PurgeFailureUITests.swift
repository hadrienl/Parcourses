import XCTest

/// Purge locale qui échoue toujours (#129), sur le serveur en mémoire de `UITestSharingGateway` :
/// `PARCOURSES_TEST_PURGE_FAILURES` fait échouer les premières purges, `PARCOURSES_TEST_PENDING_SWITCH` laisse un
/// changement de compte interrompu. Les captures `purge-…` servent à la PR (`xcrun xcresulttool export attachments`).
nonisolated final class PurgeFailureUITests: ParcoursesUITestCase {
  static let signOutMessage =
    "Vos listes sont peut-être encore sur cet appareil. Réessayez pour terminer la déconnexion."
  static let helpMessage =
    "Votre appareil manque peut-être d'espace. Libérez-en, puis réessayez. Si le problème continue, supprimez l'app puis réinstallez-la : vos listes restent dans votre compte."

  @MainActor
  private func launch(failures: Int, pendingSwitch: Bool) -> XCUIApplication {
    var settings = ["PARCOURSES_TEST_SHARING": "owner", "PARCOURSES_TEST_PURGE_FAILURES": "\(failures)"]
    if pendingSwitch { settings["PARCOURSES_TEST_PENDING_SWITCH"] = "1" }
    return launch(reset: true, settings: settings)
  }

  @MainActor
  private func openAccount(_ app: XCUIApplication) {
    let account = app.buttons["account"]
    XCTAssertTrue(account.waitForExistence(timeout: 15))
    tap(account, until: app.navigationBars["Compte"])
  }

  /// Alerte de la déconnexion, quel que soit son message.
  @MainActor
  private func signOutAlert(_ app: XCUIApplication) -> XCUIElement {
    app.alerts["La déconnexion n'a pas abouti."]
  }

  @MainActor
  private func text(_ text: String, in element: XCUIElement) -> XCUIElement {
    element.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
  }

  /// Déconnexion dont la purge échoue trois fois : l'alerte ne change pas aux deux premiers échecs, puis dit quoi faire
  /// et propose « Nous écrire ». « Réessayer » réussi la ferme et l'app repart en compte anonyme.
  @MainActor
  func testSignOutAlertOffersHelpAtTheThirdFailure() {
    let app = launch(failures: 3, pendingSwitch: false)
    openAccount(app)
    let signOut = app.buttons["signOut"]
    XCTAssertTrue(signOut.waitForExistence(timeout: 10))
    // iOS 27 expose deux fois le bouton de l'alerte (bouton et son contenu) : le premier suffit.
    let confirm = app.alerts.buttons.matching(identifier: "confirmSignOut").firstMatch
    tap(signOut, until: confirm)
    XCTAssertTrue(app.alerts["Se déconnecter ?"].exists)

    let alert = signOutAlert(app)
    let retry = alert.buttons.matching(identifier: "retrySignOut").firstMatch
    let contact = alert.buttons.matching(identifier: "contactSupport").firstMatch
    // 1ᵉʳ échec : alerte inchangée. Appui rejoué s'il se perd (#116, constaté sur la confirmation en CI).
    tap(confirm, until: retry)
    XCTAssertTrue(alert.waitForExistence(timeout: 15))
    XCTAssertTrue(text(Self.signOutMessage, in: alert).waitForExistence(timeout: 5))
    XCTAssertFalse(contact.exists)
    capture(app, "purge-alerte-1er-echec")
    // 2ᵉ échec : toujours inchangée. Le temps de laisser l'alerte se fermer, la purge échouer et l'alerte revenir.
    retry.tap()
    Thread.sleep(forTimeInterval: 2)
    XCTAssertTrue(alert.waitForExistence(timeout: 15))
    XCTAssertTrue(text(Self.signOutMessage, in: alert).waitForExistence(timeout: 5))
    XCTAssertFalse(contact.exists)
    // 3ᵉ échec : message d'aide et « Nous écrire ».
    tap(retry, until: contact)
    XCTAssertTrue(text(Self.helpMessage, in: alert).waitForExistence(timeout: 5))
    XCTAssertFalse(text(Self.signOutMessage, in: alert).exists)
    XCTAssertTrue(retry.exists)
    capture(app, "purge-alerte-3e-echec")

    // « Nous écrire » : la messagerie s'ouvre (l'app passe en arrière-plan) ou, sans app de messagerie (simulateur),
    // l'adresse s'affiche. Dans les deux cas, l'alerte revient.
    contact.tap()
    let address = app.staticTexts["supportAddress"]
    let deadline = Date.now.addingTimeInterval(15)
    while !address.exists, app.state == .runningForeground, Date.now < deadline {
      Thread.sleep(forTimeInterval: 0.3)
    }
    if address.exists {
      XCTAssertEqual(address.label, "parcourses@hadrien.eu")
      capture(app, "purge-adresse")
      app.buttons["closeSupportAddress"].tap()
    } else {
      app.activate()
    }
    XCTAssertTrue(contact.waitForExistence(timeout: 15))
    XCTAssertTrue(text(Self.helpMessage, in: alert).exists)

    // 4ᵉ essai réussi : l'alerte disparaît, l'app repart en compte anonyme.
    tap(retry, until: app.buttons["signIn"], timeout: 30)
    XCTAssertFalse(alert.exists)
  }

  /// Changement de compte interrompu dont le rejeu échoue au lancement puis à chaque retour au premier plan : le
  /// bandeau de l'écran Compte n'apparaît qu'au 3ᵉ échec. « Réessayer » réussi le fait disparaître.
  @MainActor
  func testSwitchBlockedBannerAppearsAtTheThirdFailure() {
    let app = launch(failures: 3, pendingSwitch: true)
    // 1ᵉʳ échec : rejeu du lancement.
    openAccount(app)
    let banner = app.descendants(matching: .any)["switchBlocked"]
    XCTAssertTrue(app.descendants(matching: .any)["accountEmail"].waitForExistence(timeout: 15))
    Thread.sleep(forTimeInterval: 2)
    XCTAssertFalse(banner.exists)
    // 2ᵉ échec : retour au premier plan.
    returnToForeground(app)
    XCTAssertFalse(banner.exists)
    // 3ᵉ échec : le bandeau apparaît.
    returnToForeground(app)
    XCTAssertTrue(banner.waitForExistence(timeout: 15))
    XCTAssertTrue(banner.label.contains("Changement de compte inachevé"), banner.label)
    XCTAssertTrue(banner.label.contains("La synchronisation est arrêtée."), banner.label)
    XCTAssertTrue(app.buttons["switchBlockedRetry"].exists)
    XCTAssertTrue(app.buttons["switchBlockedContact"].exists)
    capture(app, "purge-bandeau")
    // « Nous écrire » : sans app de messagerie (simulateur), l'adresse s'affiche dans le bandeau ; sinon la messagerie
    // s'ouvre et l'on revient dans l'app.
    app.buttons["switchBlockedContact"].tap()
    let address = app.staticTexts["supportAddress"]
    if address.waitForExistence(timeout: 10) {
      XCTAssertEqual(address.label, "parcourses@hadrien.eu")
    } else {
      app.activate()
    }
    XCTAssertTrue(banner.waitForExistence(timeout: 15))

    // 4ᵉ essai réussi : le bandeau disparaît.
    app.buttons["switchBlockedRetry"].tap()
    XCTAssertTrue(banner.waitForNonExistence(timeout: 15))
    XCTAssertFalse(app.buttons["switchBlockedContact"].exists)
  }
}
