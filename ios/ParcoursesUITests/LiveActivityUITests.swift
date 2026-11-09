import XCTest

/// « Cocher le suivant » depuis la Live Activity, app tuée. Vérification locale : la CI ne garantit pas les Live
/// Activities sur ses simulateurs. `TEST_RUNNER_PARCOURSES_LIVE_ACTIVITY=1 xcodebuild test …
/// -only-testing:ParcoursesUITests/LiveActivityUITests`.
nonisolated final class LiveActivityUITests: ParcoursesUITestCase {
  @MainActor
  func testCheckNextWorksWithTheAppClosed() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PARCOURSES_LIVE_ACTIVITY"] != nil, "vérification locale seulement")
    // Le système lance l'app sans l'environnement du test : tout se passe dans le store de l'App Group.
    finishLeftoverShopping()
    var app = enterShopping(confidenceQ: nil, items: ["lait", "pain"], testStore: nil)
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "2 restants")).firstMatch
        .waitForExistence(timeout: 10))
    app.terminate()
    // Pause demandée pour changer la taille du texte depuis l'hôte (`xcrun simctl ui … content_size`) : la
    // carte se vérifie aussi aux tailles d'accessibilité, que la demande de localisation empêche de traverser.
    if let pause = ProcessInfo.processInfo.environment["PARCOURSES_LIVE_ACTIVITY_PAUSE"].flatMap(Double.init) {
      print("PARCOURSES_LIVE_ACTIVITY_PAUSE \(pause)")
      _ = XCTWaiter.wait(for: [XCTestExpectation(description: "pause")], timeout: pause)
    }

    // Centre de notifications : la Live Activity y figure, avec son bouton.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.005))
    top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
    // VoiceOver nomme l'article quand l'écran n'est pas verrouillé : « Cocher lait ».
    let button = springboard.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Cocher ")).firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 10), "bouton de la Live Activity introuvable")
    let capture = XCTAttachment(screenshot: springboard.screenshot())
    capture.name = "live-activity-avant"
    capture.lifetime = .keepAlways
    add(capture)
    button.tap()
    // L'app tourne en arrière-plan le temps de l'intent ; l'activité affiche ensuite l'article suivant.
    XCTAssertTrue(
      springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1 article restant"))
        .firstMatch
        .waitForExistence(timeout: 15), "la Live Activity n'a pas suivi la coche")
    let after = XCTAttachment(screenshot: springboard.screenshot())
    after.name = "live-activity-apres"
    after.lifetime = .keepAlways
    add(after)

    app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["finish"].waitForExistence(timeout: 15))
    XCTAssertTrue(
      app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1 restant")).firstMatch
        .waitForExistence(timeout: 10))
    // Fin propre : le store de l'App Group reste d'un passage à l'autre.
    app.buttons["finish"].tap()
    app.buttons["keepRemaining"].tap()
    XCTAssertTrue(app.buttons["closeSummary"].waitForExistence(timeout: 10))
    app.buttons["closeSummary"].tap()
    // La liste créée par ce passage part aussi (le magasin semé, lui, est réutilisé au passage suivant).
    // Relancée à froid, l'app a rouvert le mode courses directement sur « Mes listes ».
    if !app.navigationBars["Mes listes"].waitForExistence(timeout: 3) { app.navigationBars.buttons.firstMatch.tap() }
    let list = app.buttons.containing(.staticText, identifier: "Samedi").firstMatch
    XCTAssertTrue(list.waitForExistence(timeout: 5))
    list.swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    let confirm = app.buttons["Supprimer la liste"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.tap()
  }

  /// Un passage précédent interrompu a pu laisser une visite ouverte, rouverte au lancement.
  @MainActor
  private func finishLeftoverShopping() {
    let app = XCUIApplication()
    app.launch()
    if app.buttons["finish"].waitForExistence(timeout: 5) {
      app.buttons["finish"].tap()
      if app.buttons["keepRemaining"].waitForExistence(timeout: 3) { app.buttons["keepRemaining"].tap() }
      if app.buttons["closeSummary"].waitForExistence(timeout: 5) { app.buttons["closeSummary"].tap() }
    }
    app.terminate()
  }
}
