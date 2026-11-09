import XCTest

// Socle commun des tests UI : lancement, lecture des lignes, captures et entrée en mode courses.
// XCTestCase est nonisolated : on sort de l'isolation MainActor par défaut.
nonisolated class ParcoursesUITestCase: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  /// `settings` : variables de lancement des réglages d'affichage forcés (voir `UITestOverrides`).
  @MainActor
  func launch(
    reset: Bool, launchArguments: [String] = [], dark: Bool = false, settings: [String: String] = [:]
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
    app.launchEnvironment.merge(settings) { _, new in new }
    app.launchArguments += launchArguments
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests"
    if reset { app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1" }
    app.launch()
    return app
  }

  /// Ligne d'article, par libellé et état annoncés à VoiceOver.
  @MainActor
  func row(_ app: XCUIApplication, _ label: String, _ state: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@ AND value == %@", label, state)).firstMatch
  }

  /// Fait défiler jusqu'à l'élément : aux grandes tailles de texte, les lignes sortent de l'écran.
  /// `betweenBars` : une ligne de liste doit aussi être entre la barre de navigation et le dock. Leurs marges ne
  /// sont pas des éléments d'accessibilité : XCUI juge « hittable » une ligne qu'elles recouvrent, et l'appui tombe
  /// sur la barre ou le dock (constaté en AX5 sur iPhone 17 : il donnait le focus au champ de saisie). Le
  /// défilement se fait alors par petits glissés, sans élan, pour ne pas dépasser la ligne.
  @MainActor
  func reveal(
    _ element: XCUIElement, in app: XCUIApplication, betweenBars: Bool = false, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var swipes = 0
    while swipes < 8 {
      guard element.waitForExistence(timeout: swipes == 0 ? 15 : 2) else {
        app.swipeUp()
        swipes += 1
        continue
      }
      let position = betweenBars ? Self.position(of: element, in: app) : (element.isHittable ? 0 : 1)
      if position == 0 { break }
      if betweenBars {
        // Glissé court (un cinquième de l'écran) : vers le haut si la ligne est sous le dock, vers le bas sinon.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: position > 0 ? 0.3 : 0.7))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
      } else {
        app.swipeUp()
      }
      swipes += 1
    }
    let reached = element.exists && (betweenBars ? Self.position(of: element, in: app) == 0 : element.isHittable)
    XCTAssertTrue(reached, "élément introuvable après défilement", file: file, line: line)
  }

  /// 0 : la ligne est entière entre la barre de navigation et le dock ; 1 : à faire monter ; -1 : à faire descendre.
  @MainActor
  private static func position(of element: XCUIElement, in app: XCUIApplication) -> Int {
    let frame = element.frame
    let bar = app.navigationBars.firstMatch
    let top = bar.exists ? bar.frame.maxY : 0
    let dock = ["shoppingEntry", "quickEntry", "undoMessage", "allChecked"].compactMap { id -> CGFloat? in
      let item = app.descendants(matching: .any).matching(identifier: id).firstMatch
      return item.exists && item.isHittable ? item.frame.minY : nil
    }
    let bottom = (dock.min() ?? app.frame.maxY) - 8
    if frame.minY < top { return -1 }
    if frame.maxY > bottom || !element.isHittable { return 1 }
    return 0
  }

  /// Capture conservée dans le `.xcresult`, sert de preuve visuelle aux PR.
  @MainActor
  func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Instantané minimal : la confiance suffit à l'en-tête, le tri lui-même est couvert par les tests unitaires.
  static func snapshot(confidenceQ: Int) -> String {
    """
    {"format_version":1,"snapshot_version":1,"params_version":1,"confidence_q":\(confidenceQ),"entries":[],"edges":[],
    "params":{"CONF_THRESHOLD_Q":500,"COST_SCALE":1000,"UNKNOWN_BASE":3000,"CAT_STEP":200,"TWO_OPT_MAX_PASSES":20,
    "REORDER_MIN_GAIN_PCT":10}}
    """
  }

  /// Crée une liste, ouvre le mode courses et choisit le magasin récent, après refus de la localisation.
  /// `testStore` à `nil` : le store de l'App Group, le seul qu'ouvre l'app lancée par le système (sans
  /// l'environnement du test).
  @MainActor
  func enterShopping(
    confidenceQ: Int?, items: [String], launchArguments: [String] = [], dark: Bool = false,
    settings: [String: String] = [:], testStore: String? = "uitests-shopping",
    atPicker: (XCUIApplication) -> Void = { _ in }
  ) -> XCUIApplication {
    let app = XCUIApplication()
    if let testStore {
      app.launchEnvironment["PARCOURSES_TEST_STORE"] = testStore
      app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    }
    app.launchEnvironment["PARCOURSES_TEST_SEED_STORE"] = "Leclerc Auch"
    app.launchEnvironment["PARCOURSES_TEST_UNDO_SECONDS"] = "60"
    if let confidenceQ {
      app.launchEnvironment["PARCOURSES_TEST_SEED_SNAPSHOT"] = Self.snapshot(confidenceQ: confidenceQ)
    }
    app.launchArguments += launchArguments
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
    app.launchEnvironment.merge(settings) { _, new in new }
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
    reveal(store, in: app)
    atPicker(app)
    store.tap()
    XCTAssertTrue(app.buttons["finish"].waitForExistence(timeout: 15))
    return app
  }
}
