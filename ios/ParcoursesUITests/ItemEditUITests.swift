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
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    XCTAssertEqual(entry.placeholderValue, "Ajouter un article (ex.\u{00A0}: 2 lait)")
    XCTAssertFalse(app.staticTexts[tip].exists)
    focus(entry)
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
      let entry = app.textFields["quickEntry"]
      tap(app.alerts.buttons["Créer"], until: entry)
      for text in [
        "2 lait demi-écrémé bio de montagne en bouteille de verre", "6x33cl bière blonde",
        "1,5 kg fromage blanc fermier au lait cru", "yaourts", "beurre",
      ] {
        focus(entry)
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

  /// Appui long en mode courses (#115, retour de la PR #136) : le menu s'ouvre pendant l'appui, et ni le relâcher ni la
  /// fermeture du menu ne cochent l'article. La bannière « Annuler » trahirait une coche.
  @MainActor
  func testLongPressOpensTheMenuWithoutChecking() {
    let app = enterShopping(confidenceQ: nil, items: ["lait", "tomates"])
    let milk = row(app, "lait", "non coché", in: "shoppingList")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    let checkedBanner = app.staticTexts.matching(identifier: "undoMessage").firstMatch
    milk.press(forDuration: 1.5)
    XCTAssertTrue(app.buttons["Quantité"].waitForExistence(timeout: 15), "menu contextuel ouvert")
    XCTAssertTrue(app.buttons["Pas trouvé"].exists)
    capture(app, "appui-long-menu")
    // Fermeture du menu par un toucher hors de la carte.
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    XCTAssertTrue(app.buttons["Quantité"].waitForNonExistence(timeout: 15), "menu refermé")
    // Une coche aurait affiché la bannière, puis envoyé la ligne au panier après 600 ms.
    XCTAssertFalse(checkedBanner.waitForExistence(timeout: 2), "l'appui long a coché l'article")
    XCTAssertTrue(row(app, "lait", "non coché", in: "shoppingList").exists)
    // Menu ouvert pendant l'appui, pas au relâcher : le doigt reste posé, puis remonte de 150 pt avant de se lever. Un
    // menu qui n'attendrait que le relâcher serait annulé par ce mouvement (iPhone, 0658856). Il n'est rien choisi :
    // le doigt se lève hors du menu, qui reste ouvert.
    let held = row(app, "lait", "non coché", in: "shoppingList").coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    held.press(
      forDuration: 1.2, thenDragTo: held.withOffset(CGVector(dx: 0, dy: -150)), withVelocity: XCUIGestureVelocity(300),
      thenHoldForDuration: 0.1)
    XCTAssertTrue(app.buttons["Quantité"].waitForExistence(timeout: 5), "menu ouvert pendant l'appui")
    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
    XCTAssertTrue(app.buttons["Quantité"].waitForNonExistence(timeout: 15), "menu refermé")
    XCTAssertFalse(checkedBanner.waitForExistence(timeout: 2), "l'appui long tenu a coché l'article")
    // Un toucher bref coche toujours.
    tap(row(app, "lait", "non coché", in: "shoppingList"), until: checkedBanner)
    XCTAssertEqual(checkedBanner.label, "lait coché")
  }

  /// Film local d'un appui long qui tremble un peu, comme un vrai doigt (#115, retour de la PR #136) : quelques points
  /// de mouvement horizontal pendant l'appui.
  @MainActor
  func testShakyLongPressFilm() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PARCOURSES_CLOSE_FILM"] != nil, "vérification locale seulement")
    let app = enterShopping(confidenceQ: nil, items: ["lait", "tomates"])
    let milk = row(app, "lait", "non coché", in: "shoppingList")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    Thread.sleep(forTimeInterval: 2)
    // Délai de l'appui long en mode courses (`APPUI` dans le journal), puis appuis qui tremblent.
    for _ in 0..<3 {
      print("APPUI courses-article \(Date.now.timeIntervalSince1970)")
      row(app, "lait", "non coché", in: "shoppingList").press(forDuration: 1.5)
      XCTAssertTrue(app.buttons["Quantité"].waitForExistence(timeout: 3))
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
      XCTAssertTrue(app.buttons["Quantité"].waitForNonExistence(timeout: 15))
      Thread.sleep(forTimeInterval: 2)
    }
    for shift in [CGFloat(-3), CGFloat(-6), CGFloat(3)] {
      let start = row(app, "lait", "non coché", in: "shoppingList").coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      start.press(
        forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: shift, dy: 0)),
        withVelocity: XCUIGestureVelocity(30), thenHoldForDuration: 1.5)
      let menu = app.buttons["Quantité"].waitForExistence(timeout: 3)
      capture(app, "appui-tremble-\(Int(shift))")
      if menu { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap() }
      Thread.sleep(forTimeInterval: 2)
      let banner = app.staticTexts.matching(identifier: "undoMessage").firstMatch
      XCTAssertFalse(banner.exists, "décalage \(shift) : l'appui long a coché")
      XCTAssertTrue(menu, "décalage \(shift) : pas de menu")
      if banner.exists {
        app.buttons["undo"].tap()
        Thread.sleep(forTimeInterval: 2)
      }
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
