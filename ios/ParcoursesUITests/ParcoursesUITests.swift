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
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    XCTAssertFalse(app.alerts.buttons["Créer"].isEnabled)
    type("Semaine", into: name, app)
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    for text in ["2 laits demi-écrémé", "tomates", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      type(text + "\n", into: entry, app)
    }

    XCTAssertTrue(row(app, "laits demi-écrémé, 2", "non coché").waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["Fruits et légumes"].exists)
    XCTAssertTrue(app.staticTexts["Crèmerie, œufs, ultra-frais"].exists)

    capture(app, "2-liste-groupee")

    row(app, "tomates", "non coché").tap()
    XCTAssertTrue(row(app, "tomates", "coché").waitForExistence(timeout: 15))

    // Dernière ligne : avec le titre de la liste en tête du ticket, elle peut passer sous le dock et le clavier.
    let xyzzy = row(app, "xyzzy", "non coché")
    reveal(xyzzy, in: app, betweenBars: true)
    xyzzy.swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    XCTAssertTrue(row(app, "xyzzy", "non coché").waitForNonExistence(timeout: 15))

    // L'autocomplétion retrouve un article coché.
    entry.tap()
    type("3 tom", into: entry, app)
    // Libellé VoiceOver (l'identifiant de la puce est « suggestion »).
    let chip = app.buttons.matching(NSPredicate(format: "label == %@", "Ajouter tomates")).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15))
    capture(app, "3-autocompletion")
    chip.tap()
    XCTAssertTrue(row(app, "tomates, 3", "non coché").waitForExistence(timeout: 15))

    app.terminate()
    app = launch(reset: false)
    let list = app.staticTexts["Semaine"]
    XCTAssertTrue(list.waitForExistence(timeout: 15))
    list.tap()
    XCTAssertTrue(row(app, "laits demi-écrémé, 2", "non coché").waitForExistence(timeout: 15))
    XCTAssertTrue(row(app, "tomates", "coché").exists)
    XCTAssertTrue(row(app, "tomates, 3", "non coché").exists)
    XCTAssertFalse(row(app, "xyzzy", "non coché").exists)
    capture(app, "4-apres-relance")

    // Retour à l'écran Listes, suppression de la liste, toujours supprimée après relance.
    app.navigationBars.buttons.firstMatch.tap()
    let row = app.buttons.containing(.staticText, identifier: "Semaine").firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    capture(app, "5-mes-listes")
    row.swipeLeft()
    app.buttons["Supprimer"].firstMatch.tap()
    let confirm = app.buttons["Supprimer la liste"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 15))
    confirm.tap()
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
  }

  /// Parcours du mode courses : coche, annulation, introuvable, ajout en route, fin et résumé.
  @MainActor
  func testShoppingJourney() {
    let app = enterShopping(confidenceQ: nil, items: ["2 laits", "tomates", "yaourts bio", "xyzzy"])
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 15))
    capture(app, "2-liste-triee-inconnu")

    // Coche et annulation.
    // Une coche, une seule : une coche rejouée aurait décoché les tomates, et le panier resterait vide.
    tap(row(app, "tomates", "non coché", in: "shoppingList"), until: app.buttons["undo"])
    XCTAssertTrue(app.staticTexts["Dans le panier (1)"].waitForExistence(timeout: 15))
    capture(app, "3-annulation")
    tap(app.buttons["undo"], until: row(app, "tomates", "non coché", in: "shoppingList"))

    // La coche rejoint le panier après le délai d'inactivité. La ligne « coché » ne reste dans son rayon que ces
    // 600 ms : l'effet attendu est le panier.
    tap(row(app, "tomates", "non coché", in: "shoppingList"), until: app.staticTexts["Dans le panier (1)"])

    // Introuvable.
    row(app, "xyzzy", "non coché", in: "shoppingList").swipeLeft()
    app.buttons["Pas trouvé"].firstMatch.tap()
    XCTAssertTrue(row(app, "xyzzy", "introuvable", in: "shoppingList").waitForExistence(timeout: 15))
    capture(app, "4-introuvable")

    // Ajout en route.
    let entry = app.textFields["shoppingEntry"]
    entry.tap()
    type("pommes\n", into: entry, app)
    XCTAssertTrue(row(app, "pommes", "non coché", in: "shoppingList").waitForExistence(timeout: 15))
    capture(app, "5-ajout-en-route")

    // Fin : la sheet demande quoi faire des articles restants.
    app.swipeDown()
    app.buttons["finish"].tap()
    XCTAssertTrue(app.buttons["keepRemaining"].waitForExistence(timeout: 15))
    capture(app, "6-articles-restants")
    app.buttons["keepRemaining"].tap()
    XCTAssertTrue(app.buttons["closeSummary"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["1 article"].exists)
    capture(app, "7-resume")
    app.buttons["closeSummary"].tap()
    XCTAssertTrue(row(app, "tomates", "coché").waitForExistence(timeout: 15))
    XCTAssertTrue(row(app, "pommes", "non coché").exists)
  }

  /// En-têtes selon ce que l'instantané en cache sait du magasin.
  @MainActor
  func testLearnedStoreHeader() {
    let app = enterShopping(confidenceQ: 720, items: ["lait", "tomates"])
    XCTAssertTrue(app.staticTexts["Trajet connu à 72 %"].waitForExistence(timeout: 15))
    capture(app, "8-appris")
  }

  @MainActor
  func testLearningStoreHeader() {
    let app = enterShopping(confidenceQ: 300, items: ["lait", "tomates"])
    XCTAssertTrue(app.staticTexts["Trajet en apprentissage (30 %)"].waitForExistence(timeout: 15))
    capture(app, "9-en-apprentissage")
  }

  /// Ordre non appris : les articles se lisent par rayon, avec un titre par rayon.
  @MainActor
  func testUnknownOrderIsGroupedByAisle() {
    let app = enterShopping(
      confidenceQ: nil, items: ["lait", "tomates", "saucisse", "lessive", "moutarde", "papier toilette"])
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["aisle-dairy"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["aisle-butcher"].exists)
    XCTAssertTrue(row(app, "lait", "non coché").exists)
    capture(app, "10-groupe-par-rayon")
  }

  /// Instantané en apprentissage : même présentation par rayon.
  @MainActor
  func testLearningOrderIsGroupedByAisle() {
    let app = enterShopping(confidenceQ: 300, items: ["lait", "tomates", "saucisse"])
    XCTAssertTrue(app.staticTexts["aisle-dairy"].waitForExistence(timeout: 15))
    capture(app, "11-apprentissage-groupe")
  }

  /// Instantané appris : l'ordre du trajet est gardé, et ses rayons se lisent le long du fil (B3, lot 9.11).
  @MainActor
  func testLearnedOrderShowsAislesAlongTheRoute() {
    let app = enterShopping(confidenceQ: 720, items: ["lait", "tomates", "saucisse"])
    XCTAssertTrue(app.staticTexts["Trajet connu à 72 %"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["aisle-dairy"].exists)
    capture(app, "12-appris-rayons-sur-le-fil")
  }

  /// Une visite ouverte est rouverte au lancement.
  @MainActor
  func testOpenVisitReopensAtLaunch() {
    var app = enterShopping(confidenceQ: nil, items: ["lait", "tomates"])
    XCTAssertTrue(row(app, "tomates", "non coché").waitForExistence(timeout: 15))
    app.terminate()
    app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-shopping"
    app.launch()
    XCTAssertTrue(app.buttons["finish"].waitForExistence(timeout: 15))
    XCTAssertTrue(row(app, "tomates", "non coché").exists)
  }

  /// Champ de saisie (`EntryFieldStyle`) : le geste qui donne le focus à toute la case ne prend pas la place des
  /// gestes d'édition. Un appui dans le texte place le curseur, un double appui sélectionne le mot, un appui dans la
  /// marge de la case donne le focus.
  @MainActor
  func testEntryFieldKeepsEditingGestures() {
    let app = launch(reset: true)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    type("Semaine", into: name, app)
    // Le cadre de l'élément est celui de la case : le texte commence après sa marge de 12 pt.
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    if !entry.hasFocus { entry.tap() }
    // Mots justes en français comme en anglais : un appui sur un mot souligné par le correcteur (clavier anglais
    // du simulateur de CI) le sélectionne au lieu d'y placer le curseur.
    type("orange melon", into: entry, app)
    func point(_ x: CGFloat) -> XCUICoordinate {
      entry.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: entry.frame.height / 2))
    }

    // Appui au début du texte : le curseur s'y place, la frappe s'insère devant.
    point(14).tap()
    type("x", into: entry, app)
    XCTAssertEqual(entry.value as? String, "xorange melon")

    // Double appui sur le premier mot : il est sélectionné, la frappe le remplace.
    point(22).doubleTap()
    type("kiwi", into: entry, app)
    XCTAssertEqual(entry.value as? String, "kiwi melon")
    capture(app, "saisie-double-appui")

    // Ajout, puis retour sur la liste, qui ne prend plus le focus d'elle-même une fois remplie : un appui dans la
    // marge droite de la case, hors du texte, donne le focus.
    type("\n", into: entry, app)
    XCTAssertTrue(row(app, "kiwi melon", "non coché").waitForExistence(timeout: 15))
    app.navigationBars.buttons.firstMatch.tap()
    // Écran de la liste parti : son titre (« Semaine », dans le ticket) ne répond plus à la recherche.
    XCTAssertTrue(app.descendants(matching: .any)["listTitle"].waitForNonExistence(timeout: 15))
    let list = app.staticTexts["Semaine"]
    XCTAssertTrue(list.waitForExistence(timeout: 15))
    list.tap()
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    XCTAssertFalse(entry.hasFocus)
    point(entry.frame.width - 4).tap()
    // Seul champ de l'écran : le clavier suffit à montrer qu'il a le focus.
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 15))
  }
}
