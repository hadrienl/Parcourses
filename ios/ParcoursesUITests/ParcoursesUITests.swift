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
      focus(entry)
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
    // Glisser maison (#115) : un seul bouton, celui de la ligne ouverte, hors de l'élément de la ligne.
    XCTAssertTrue(app.buttons["Supprimer"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.buttons.matching(identifier: "Supprimer").count, 1)
    capture(app, "2b-ligne-ouverte")
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
    // Une coche, une seule : un second appui reçu (le premier arrivé en retard) aurait décoché les tomates et retiré
    // la bannière.
    tap(row(app, "tomates", "non coché", in: "shoppingList"), until: app.buttons["undo"])
    XCTAssertEqual(app.staticTexts.matching(identifier: "undoMessage").firstMatch.label, "tomates coché")
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

  /// Glisser maison du mode courses (#115) : un glisser tenu ouvre la ligne sans bouger le fil, un toucher la referme,
  /// et le glisser complet passe l'article dans « Introuvable » sans toucher le bouton. Puis captures du trait dans
  /// les situations où ses mesures pourraient décrocher : feuille « Quantité », défilement rapide, panier en bas de
  /// liste replié et déplié.
  @MainActor
  func testFullSwipeMarksNotFound() {
    let app = enterShopping(
      confidenceQ: nil,
      items: [
        "lait", "tomates", "xyzzy", "pain", "beurre", "yaourts", "jambon", "lessive", "café", "riz", "pâtes", "oeufs",
      ])
    let milk = row(app, "lait", "non coché", in: "shoppingList")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["Pas trouvé"].exists, "le bouton n'existe que ligne ouverte")

    // Glisser lent, tenu : capture pendant le geste, puis la ligne reste ouverte au relâcher.
    milk.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(
      forDuration: 0.05, thenDragTo: milk.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.5)
    let notFound = app.buttons["Pas trouvé"]
    XCTAssertTrue(notFound.waitForExistence(timeout: 15), "le glisser ouvre la ligne")
    XCTAssertEqual(app.buttons.matching(identifier: "Pas trouvé").count, 1)
    capture(app, "glisser-ouvert")

    // Toucher la ligne ouverte la referme, sans la cocher.
    row(app, "lait", "non coché", in: "shoppingList").tap()
    XCTAssertTrue(notFound.waitForNonExistence(timeout: 15), "le toucher referme la ligne")
    XCTAssertTrue(row(app, "lait", "non coché", in: "shoppingList").exists)

    // Glisser complet : au-delà de 60 % du couloir, l'action part au relâcher.
    let start = milk.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
    start.press(
      forDuration: 0.05, thenDragTo: milk.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
      withVelocity: .slow, thenHoldForDuration: 0.2)
    // « Introuvable » est sous la ligne de flottaison avec ces douze articles : la bannière dit ce qui s'est passé.
    let message = app.staticTexts.matching(identifier: "undoMessage").firstMatch
    XCTAssertTrue(message.waitForExistence(timeout: 15))
    XCTAssertEqual(message.label, "lait introuvable")
    XCTAssertTrue(row(app, "tomates", "non coché", in: "shoppingList").exists)
    capture(app, "glisser-complet")
    threadCaptures(app)
  }

  /// Captures du trait unique (#115, relecture de la PR #136) : à regarder, le trait doit passer par les perles, sans
  /// trou ni dépassement.
  @MainActor
  private func threadCaptures(_ app: XCUIApplication) {
    let list = app.collectionViews["shoppingList"]
    // Un article au panier, pour avoir le panier en bas de liste (sous la ligne de flottaison : la bannière fait foi).
    let checked = app.staticTexts.matching(
      NSPredicate(format: "identifier == %@ AND label == %@", "undoMessage", "tomates coché")
    ).firstMatch
    tap(row(app, "tomates", "non coché", in: "shoppingList"), until: checked)

    // Feuille « Quantité » ouverte, puis refermée.
    let bread = row(app, "pain", "non coché", in: "shoppingList")
    reveal(bread, in: app, betweenBars: true)
    bread.press(forDuration: 1.2)
    let quantity = app.buttons["Quantité"]
    XCTAssertTrue(quantity.waitForExistence(timeout: 15))
    quantity.tap()
    let save = app.buttons["saveItem"]
    XCTAssertTrue(save.waitForExistence(timeout: 15))
    capture(app, "fil-feuille-quantite-ouverte")
    save.tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 15))
    capture(app, "fil-feuille-quantite-fermee")

    // Défilement rapide : captures pendant l'élan.
    list.swipeUp(velocity: .fast)
    capture(app, "fil-defilement-rapide-1")
    capture(app, "fil-defilement-rapide-2")
    list.swipeDown(velocity: .fast)
    capture(app, "fil-defilement-rapide-3")

    // Tout en bas, panier déplié puis replié.
    for _ in 0..<3 { list.swipeUp() }
    let basket = app.descendants(matching: .any)["basket"].firstMatch
    XCTAssertTrue(basket.waitForExistence(timeout: 15))
    capture(app, "fil-bas-de-liste")
    basket.tap()
    capture(app, "fil-panier-deplie")
    basket.tap()
    capture(app, "fil-panier-replie")
  }

  /// Glisser vers la fin de ligne sur l'écran Liste (#115) : ligne ouverte, il la referme sans quitter l'écran ; ligne
  /// fermée, il laisse passer le geste retour plein écran d'iOS 26 et ramène à « Mes listes ».
  @MainActor
  func testRightSwipeClosesAnOpenRowOrGoesBack() {
    let app = launch(reset: true)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    type("Semaine", into: name, app)
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    for text in ["tomates", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      type(text + "\n", into: entry, app)
    }
    let tomatoes = row(app, "tomates", "non coché")
    XCTAssertTrue(tomatoes.waitForExistence(timeout: 15))

    // Ligne ouverte : le glisser vers la droite la referme, l'écran reste.
    tomatoes.swipeLeft()
    let delete = app.buttons["Supprimer"]
    XCTAssertTrue(delete.waitForExistence(timeout: 15))
    row(app, "tomates", "non coché").swipeRight()
    XCTAssertTrue(delete.waitForNonExistence(timeout: 15), "le glisser vers la droite referme la ligne")
    XCTAssertTrue(app.descendants(matching: .any)["listTitle"].exists, "l'écran Liste reste affiché")
    XCTAssertTrue(row(app, "tomates", "non coché").exists)

    // Ligne fermée : le geste retour plein écran (iOS 26) l'emporte, depuis le milieu de la ligne.
    row(app, "tomates", "non coché").swipeRight()
    if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 {
      XCTAssertTrue(app.navigationBars["Mes listes"].waitForExistence(timeout: 15), "retour à « Mes listes »")
    } else {
      // iOS 18 : pas de geste retour plein écran, rien ne se passe.
      XCTAssertFalse(delete.exists)
      XCTAssertTrue(app.descendants(matching: .any)["listTitle"].exists)
    }
  }

  /// Capture locale en écriture de droite à gauche : gouttière et trait à droite, sur les perles.
  /// `TEST_RUNNER_PARCOURSES_RTL_CAPTURE=1 xcodebuild test … -only-testing:…/testRightToLeftThreadCapture`.
  @MainActor
  func testRightToLeftThreadCapture() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["PARCOURSES_RTL_CAPTURE"] != nil, "vérification locale seulement")
    let app = launch(
      reset: true, launchArguments: ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES"])
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 15))
    type("Semaine", into: name, app)
    let entry = app.textFields["quickEntry"]
    tap(app.alerts.buttons["Créer"], until: entry)
    for text in ["tomates", "2 laits", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      type(text + "\n", into: entry, app)
    }
    let milk = row(app, "laits, 2", "non coché")
    XCTAssertTrue(milk.waitForExistence(timeout: 15))
    capture(app, "fil-rtl-repos")
    milk.swipeRight()
    XCTAssertTrue(app.buttons["Supprimer"].waitForExistence(timeout: 15), "swipeRight ouvre la ligne en RTL")
    capture(app, "fil-rtl-ouvert")
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
    focus(entry)
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
