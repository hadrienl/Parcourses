import XCTest

/// Captures App Store (#145), prises par `fastlane screenshots` (schéma `ParcoursesScreenshots`, `capture_screenshots`)
/// sur le serveur en mémoire du scénario `demo` (`UITestSharingGateway`, `UITestDemoData`) et une position imposée
/// devant le Supermarché des Halles (`UITestLocationProvider`) : ni réseau, ni demande de localisation.
///
/// `snapshot(_:)` écrit l'image là où fastlane l'attend ; `capture(_:_:)` la garde aussi dans le `.xcresult`, pour la
/// relire sans fastlane. Exclue du schéma `Parcourses` (CI) : elle y est compilée, pas jouée.
nonisolated final class AppStoreScreenshotTests: ParcoursesUITestCase {
  @MainActor
  func testAppStoreScreenshots() {
    let app = XCUIApplication()
    setupSnapshot(app)
    app.launchEnvironment["PARCOURSES_TEST_SHARING"] = "demo"
    app.launchEnvironment["PARCOURSES_TEST_LOCATION"] = "43.6455,0.5853"
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-screenshots"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    // Bannière « Annuler » brève : aucune ne doit rester sur une capture.
    app.launchEnvironment["PARCOURSES_TEST_UNDO_SECONDS"] = "1"
    app.launch()

    // Liste partagée : pastilles des membres, marque d'auteur de Léa, dernière modification.
    openList(app, "Courses de la semaine")
    XCTAssertTrue(app.buttons["listMembers"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.descendants(matching: .any)["lastChange"].waitForExistence(timeout: 10))
    shoot(app, "04-liste-partagee")

    goBack(app)

    // Saisie rapide dans une liste neuve, assez courte pour rester visible au-dessus du clavier : « mozarella » et
    // « yahourt », mal orthographiés, rangés en fromages et en crèmerie.
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    type("Pique-nique", into: name, app)
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    for text in ["Mozarella", "Yahourt"] {
      focus(entry)
      type(text + "\n", into: entry, app)
      let added = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
      XCTAssertTrue(added.waitForExistence(timeout: 10))
    }
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    shoot(app, "05-saisie")
    goBack(app)

    // Liste des captures du mode courses.
    openList(app, "Courses de samedi")
    tap(app.buttons["startShopping"], until: app.navigationBars["Choisir le magasin"])

    // Choix du magasin : le plus proche proposé, deux autres à côté.
    let confirm = app.buttons["confirmProposal"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 15))
    let other = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Supérette du Centre")).firstMatch
    XCTAssertTrue(other.waitForExistence(timeout: 5))
    shoot(app, "02-magasin")

    // Liste dans l'ordre du trajet appris.
    tap(confirm, until: app.buttons["finish"])
    let route = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Trajet connu à 82")).firstMatch
    XCTAssertTrue(route.waitForExistence(timeout: 15))
    let bread = item(app, "Pain de campagne")
    XCTAssertTrue(bread.waitForExistence(timeout: 10))
    shoot(app, "01-liste-triee")

    // Mode courses en cours : les trois premiers articles du trajet cochés, le fil avance jusqu'aux pâtes.
    // L'effet attendu est le compteur de l'en-tête : « Dans le panier (n) », en bas d'une longue liste, n'est pas
    // dans l'arbre d'accessibilité tant qu'il est hors de l'écran.
    for (count, label) in ["Pain de campagne", "Tomates", "Basilic"].enumerated() {
      let remaining = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier == %@ AND label == %@", "shoppingHeader", "\(9 - count) restants"))
        .firstMatch
      tap(item(app, label), until: remaining)
    }
    // Les lignes cochées rejoignent le panier replié, et la bannière « Annuler » s'en va.
    let checked = app.collectionViews["shoppingList"].descendants(matching: .any)
      .matching(NSPredicate(format: "value == %@", "coché")).firstMatch
    XCTAssertTrue(checked.waitForNonExistence(timeout: 10), "ligne cochée encore dans son rayon")
    XCTAssertTrue(app.buttons["undo"].waitForNonExistence(timeout: 10), "bannière « Annuler » encore affichée")
    shoot(app, "03-mode-courses")
  }

  /// Ligne de Mes listes, une fois descendue du serveur en mémoire.
  @MainActor
  private func openList(_ app: XCUIApplication, _ name: String) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    reveal(row, in: app)
    tap(row, until: app.descendants(matching: .any)["itemList"])
  }

  /// Retour à Mes listes par le bouton de la barre de navigation (le premier, avant les membres et le chariot).
  @MainActor
  private func goBack(_ app: XCUIApplication) {
    tap(app.navigationBars.buttons.element(boundBy: 0), until: app.buttons["Nouvelle liste"])
  }

  /// Article encore à prendre du mode courses (« Tomates, 6 »).
  @MainActor
  private func item(_ app: XCUIApplication, _ label: String) -> XCUIElement {
    app.collectionViews["shoppingList"].descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@ AND value == %@", label + ",", "non coché")).firstMatch
  }

  @MainActor
  private func shoot(_ app: XCUIApplication, _ name: String) {
    // Par la classe de fastlane : `snapshot(confidenceQ:)` de `ParcoursesUITestCase` masque la fonction libre
    // `snapshot(_:)`, qui ne fait que l'appeler.
    Snapshot.snapshot(name)
    capture(app, name)
  }
}
