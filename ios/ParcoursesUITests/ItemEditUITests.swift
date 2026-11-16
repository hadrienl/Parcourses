import XCTest

/// Quantité d'un article (#110) : invite de saisie, astuce unique, appui long et panneau de l'article, saisie sur un
/// article existant, « Quantité » du mode courses.
nonisolated final class ItemEditUITests: ParcoursesUITestCase {
  private let tip = "Maintiens un article pour changer sa quantité"

  @MainActor
  func testLongPressEditsTheItemAndTheTipShowsOnce() {
    // Astuces activées et remises à zéro : aucun article encore ajouté.
    let app = launch(reset: true, settings: ["PARCOURSES_TEST_TIPS": "1"])
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    type("Semaine", into: name, app)
    app.alerts.buttons["Créer"].tap()

    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    XCTAssertEqual(entry.placeholderValue, "Ajouter un article (ex.\u{00A0}: 2 lait)")
    XCTAssertFalse(app.staticTexts[tip].exists)
    if !entry.hasFocus { entry.tap() }
    type("lait\n", into: entry, app)

    // Premier article : l'astuce apparaît.
    let milk = row(app, "lait", "non coché")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts[tip].waitForExistence(timeout: 15))
    capture(app, "1-astuce")

    // Appui long : le panneau de l'article s'ouvre, sans cocher.
    milk.press(forDuration: 1.0)
    let save = app.buttons["saveItem"]
    XCTAssertTrue(save.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["quantityDecrement"].isEnabled)
    app.buttons["quantityIncrement"].tap()
    app.buttons["unit-kg"].tap()
    XCTAssertEqual(app.textFields["quantityField"].value as? String, "2 kg")
    capture(app, "2-panneau")
    save.tap()
    XCTAssertTrue(row(app, "lait, 2 kg", "non coché").waitForExistence(timeout: 15))
    // L'astuce a servi : elle ne revient plus.
    XCTAssertFalse(app.staticTexts[tip].exists)

    // Saisie sur l'article existant : sa quantité change, pas de doublon.
    entry.tap()
    type("lait x3\n", into: entry, app)
    XCTAssertTrue(row(app, "lait, 3", "non coché").waitForExistence(timeout: 15))
    XCTAssertFalse(row(app, "lait, 2 kg", "non coché").exists)
    XCTAssertFalse(row(app, "lait", "non coché").exists)
    capture(app, "3-saisie-sur-un-article-existant")

    // Toucher coche toujours.
    row(app, "lait, 3", "non coché").tap()
    XCTAssertTrue(row(app, "lait, 3", "coché").waitForExistence(timeout: 15))
  }

  /// Libellé long, quantité longue, les deux (#110) : seul le libellé se replie, la quantité reste à droite sur sa
  /// dernière ligne, reliée par les points de conduite (ou passe dessous si elle prendrait trop de place). Captures en
  /// taille par défaut et en AX5.
  @MainActor
  func testLongLabelsAndQuantitiesCaptures() {
    let sizes: [(arguments: [String], suffix: String)] = [
      ([], "defaut"),
      (["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"], "ax5"),
    ]
    for size in sizes {
      let app = launch(reset: true, launchArguments: size.arguments)
      XCTAssertTrue(app.buttons["Nouvelle liste"].waitForExistence(timeout: 15))
      app.buttons["Nouvelle liste"].tap()
      let name = app.alerts.textFields.firstMatch
      XCTAssertTrue(name.waitForExistence(timeout: 15))
      type("Semaine", into: name, app)
      app.alerts.buttons["Créer"].tap()
      let entry = app.textFields["quickEntry"]
      XCTAssertTrue(entry.waitForExistence(timeout: 15))
      for text in [
        "2 lait demi-écrémé bio de montagne en bouteille de verre", "6x33cl bière blonde",
        "1,5 kg fromage blanc fermier au lait cru", "yaourts", "beurre",
      ] {
        if !entry.hasFocus { entry.tap() }
        type(text + "\n", into: entry, app)
      }
      // Quantité trop longue pour la colonne de droite (saisie libre du panneau) : elle passe sous le libellé. En
      // taille par défaut seulement : en AX5 sur iOS 18, la ligne reste hors d'atteinte du défilement sous le clavier.
      if size.arguments.isEmpty {
        let butter = row(app, "beurre", "non coché")
        reveal(butter, in: app, betweenBars: true)
        butter.press(forDuration: 1.0)
        let quantity = app.textFields["quantityField"]
        XCTAssertTrue(quantity.waitForExistence(timeout: 15))
        quantity.tap()
        type("2 plaquettes de 250 g doux", into: quantity, app)
        app.buttons["saveItem"].tap()
        XCTAssertTrue(app.buttons["saveItem"].waitForNonExistence(timeout: 15))
      }
      // Clavier fermé (glisser la liste) : les lignes sont visibles pour la capture.
      app.collectionViews["itemList"].swipeDown()
      // En AX5, les lignes débordent de l'écran : seule la capture compte.
      if size.arguments.isEmpty {
        XCTAssertTrue(row(app, "yaourts", "non coché").waitForExistence(timeout: 15))
        XCTAssertTrue(row(app, "lait demi-écrémé bio de montagne en bouteille de verre, 2", "non coché").exists)
        XCTAssertTrue(row(app, "fromage blanc fermier au lait cru, 1,5 kg", "non coché").exists)
        XCTAssertTrue(row(app, "beurre, 2 plaquettes de 250 g doux", "non coché").exists)
      } else {
        Thread.sleep(forTimeInterval: 1)
      }
      capture(app, "lignes-longues-\(size.suffix)")
      app.terminate()
    }
  }

  @MainActor
  func testShoppingMenuOpensTheQuantitySheet() {
    let app = enterShopping(confidenceQ: nil, items: ["lait", "tomates"])
    let milk = row(app, "lait", "non coché", in: "shoppingList")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    milk.press(forDuration: 1.2)
    let quantity = app.buttons["Quantité"]
    XCTAssertTrue(quantity.waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["Pas trouvé"].exists)
    quantity.tap()
    XCTAssertTrue(app.buttons["saveItem"].waitForExistence(timeout: 15))
    app.buttons["quantityIncrement"].tap()
    app.buttons["saveItem"].tap()
    XCTAssertTrue(row(app, "lait, 2", "non coché", in: "shoppingList").waitForExistence(timeout: 15))
  }
}
