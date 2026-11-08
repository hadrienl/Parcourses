import XCTest

nonisolated final class ParcoursesUITests: ParcoursesUITestCase {
  /// Parcours complet : créer, ajouter, voir groupé, cocher, supprimer, relancer et tout retrouver.
  @MainActor
  func testListJourneySurvivesRelaunch() {
    var app = launch(reset: true)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    capture(app, "1-listes-vide")

    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertFalse(app.alerts.buttons["Créer"].isEnabled)
    name.typeText("Semaine")
    app.alerts.buttons["Créer"].tap()

    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    for text in ["2 laits demi-écrémé", "tomates", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      entry.typeText(text + "\n")
    }

    XCTAssertTrue(row(app, "laits demi-écrémé, 2", "non coché").waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Fruits et légumes"].exists)
    XCTAssertTrue(app.staticTexts["Crèmerie, œufs, ultra-frais"].exists)

    capture(app, "2-liste-groupee")

    row(app, "tomates", "non coché").tap()
    XCTAssertTrue(row(app, "tomates", "coché").waitForExistence(timeout: 5))

    row(app, "xyzzy", "non coché").swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    XCTAssertTrue(row(app, "xyzzy", "non coché").waitForNonExistence(timeout: 5))

    // L'autocomplétion retrouve un article coché.
    entry.tap()
    entry.typeText("3 tom")
    // Libellé VoiceOver (l'identifiant de la puce est « suggestion »).
    let chip = app.buttons.matching(NSPredicate(format: "label == %@", "Ajouter tomates")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 5))
    capture(app, "3-autocompletion")
    chip.tap()
    XCTAssertTrue(row(app, "tomates, 3", "non coché").waitForExistence(timeout: 5))

    app.terminate()
    app = launch(reset: false)
    let list = app.staticTexts["Semaine"]
    XCTAssertTrue(list.waitForExistence(timeout: 15))
    list.tap()
    XCTAssertTrue(row(app, "laits demi-écrémé, 2", "non coché").waitForExistence(timeout: 5))
    XCTAssertTrue(row(app, "tomates", "coché").exists)
    XCTAssertTrue(row(app, "tomates, 3", "non coché").exists)
    XCTAssertFalse(row(app, "xyzzy", "non coché").exists)
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

  /// Parcours du mode courses : coche, annulation, introuvable, ajout en route, fin et résumé.
  @MainActor
  func testShoppingJourney() {
    let app = enterShopping(confidenceQ: nil, items: ["2 laits", "tomates", "yaourts bio", "xyzzy"])
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 5))
    capture(app, "2-liste-triee-inconnu")

    // Coche et annulation.
    row(app, "tomates", "non coché").tap()
    XCTAssertTrue(app.buttons["undo"].waitForExistence(timeout: 3))
    capture(app, "3-annulation")
    app.buttons["undo"].tap()
    XCTAssertTrue(row(app, "tomates", "non coché").waitForExistence(timeout: 3))

    // La coche rejoint le panier après le délai d'inactivité.
    row(app, "tomates", "non coché").tap()
    XCTAssertTrue(app.staticTexts["Dans le panier (1)"].waitForExistence(timeout: 5))

    // Introuvable.
    row(app, "xyzzy", "non coché").swipeLeft()
    app.buttons["Pas trouvé"].firstMatch.tap()
    XCTAssertTrue(row(app, "xyzzy", "introuvable").waitForExistence(timeout: 5))
    capture(app, "4-introuvable")

    // Ajout en route.
    let entry = app.textFields["shoppingEntry"]
    entry.tap()
    entry.typeText("pommes\n")
    XCTAssertTrue(row(app, "pommes", "non coché").waitForExistence(timeout: 5))
    capture(app, "5-ajout-en-route")

    // Fin : la sheet demande quoi faire des articles restants.
    app.swipeDown()
    app.buttons["finish"].tap()
    XCTAssertTrue(app.buttons["keepRemaining"].waitForExistence(timeout: 5))
    capture(app, "6-articles-restants")
    app.buttons["keepRemaining"].tap()
    XCTAssertTrue(app.buttons["closeSummary"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["1 article"].exists)
    capture(app, "7-resume")
    app.buttons["closeSummary"].tap()
    XCTAssertTrue(row(app, "tomates", "coché").waitForExistence(timeout: 5))
    XCTAssertTrue(row(app, "pommes", "non coché").exists)
  }

  /// En-têtes selon ce que l'instantané en cache sait du magasin.
  @MainActor
  func testLearnedStoreHeader() {
    let app = enterShopping(confidenceQ: 720, items: ["lait", "tomates"])
    XCTAssertTrue(app.staticTexts["Trajet connu à 72 %"].waitForExistence(timeout: 5))
    capture(app, "8-appris")
  }

  @MainActor
  func testLearningStoreHeader() {
    let app = enterShopping(confidenceQ: 300, items: ["lait", "tomates"])
    XCTAssertTrue(app.staticTexts["Trajet en apprentissage (30 %)"].waitForExistence(timeout: 5))
    capture(app, "9-en-apprentissage")
  }

  /// Ordre non appris : les articles se lisent par rayon, avec un titre par rayon.
  @MainActor
  func testUnknownOrderIsGroupedByAisle() {
    let app = enterShopping(
      confidenceQ: nil, items: ["lait", "tomates", "saucisse", "lessive", "moutarde", "papier toilette"])
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["aisle-dairy"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["aisle-butcher"].exists)
    XCTAssertTrue(row(app, "lait", "non coché").exists)
    capture(app, "10-groupe-par-rayon")
  }

  /// Instantané en apprentissage : même présentation par rayon.
  @MainActor
  func testLearningOrderIsGroupedByAisle() {
    let app = enterShopping(confidenceQ: 300, items: ["lait", "tomates", "saucisse"])
    XCTAssertTrue(app.staticTexts["aisle-dairy"].waitForExistence(timeout: 5))
    capture(app, "11-apprentissage-groupe")
  }

  /// Instantané appris : fil continu, sans titres de rayon.
  @MainActor
  func testLearnedOrderHasNoAisleTitles() {
    let app = enterShopping(confidenceQ: 720, items: ["lait", "tomates", "saucisse"])
    XCTAssertTrue(app.staticTexts["Trajet connu à 72 %"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["aisle-dairy"].exists)
    capture(app, "12-appris-fil-continu")
  }

  /// Une visite ouverte est rouverte au lancement.
  @MainActor
  func testOpenVisitReopensAtLaunch() {
    var app = enterShopping(confidenceQ: nil, items: ["lait", "tomates"])
    XCTAssertTrue(row(app, "tomates", "non coché").waitForExistence(timeout: 5))
    app.terminate()
    app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-shopping"
    app.launch()
    XCTAssertTrue(app.buttons["finish"].waitForExistence(timeout: 15))
    XCTAssertTrue(row(app, "tomates", "non coché").exists)
  }
}
