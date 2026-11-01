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

  /// Ligne d'article, par libellé et état annoncés à VoiceOver.
  @MainActor
  private func row(_ app: XCUIApplication, _ label: String, _ state: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@ AND value == %@", label, state)).firstMatch
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
    let chip = app.buttons["Ajouter tomates"]
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

  /// Instantané minimal : la confiance suffit à l'en-tête, le tri lui-même est couvert par les tests unitaires.
  private static func snapshot(confidenceQ: Int) -> String {
    """
    {"format_version":1,"snapshot_version":1,"params_version":1,"confidence_q":\(confidenceQ),"entries":[],"edges":[],
    "params":{"CONF_THRESHOLD_Q":500,"COST_SCALE":1000,"UNKNOWN_BASE":3000,"CAT_STEP":200,"TWO_OPT_MAX_PASSES":20,
    "REORDER_MIN_GAIN_PCT":10}}
    """
  }

  /// Crée une liste, ouvre le mode courses et choisit le magasin récent, après refus de la localisation.
  @MainActor
  private func enterShopping(confidenceQ: Int?, items: [String]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-shopping"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    app.launchEnvironment["PARCOURSES_TEST_SEED_STORE"] = "Leclerc Auch"
    if let confidenceQ {
      app.launchEnvironment["PARCOURSES_TEST_SEED_SNAPSHOT"] = Self.snapshot(confidenceQ: confidenceQ)
    }
    app.resetAuthorizationStatus(for: .location)
    app.launch()

    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 10))
    name.typeText("Samedi")
    app.alerts.buttons["Créer"].tap()
    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    for text in items {
      if !entry.hasFocus { entry.tap() }
      entry.typeText(text + "\n")
    }
    app.buttons["startShopping"].tap()

    // La demande système n'apparaît qu'ici, au premier passage en mode courses.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let prompt = springboard.alerts.firstMatch
    XCTAssertTrue(prompt.waitForExistence(timeout: 15), "demande de localisation attendue")
    capture(app, "1-demande-localisation")
    prompt.buttons.element(boundBy: prompt.buttons.count - 1).tap()

    let store = app.buttons.containing(.staticText, identifier: "Leclerc Auch").firstMatch
    XCTAssertTrue(store.waitForExistence(timeout: 15))
    store.tap()
    XCTAssertTrue(app.buttons["finish"].waitForExistence(timeout: 15))
    return app
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
