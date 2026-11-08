import XCTest

// Socle commun des tests UI : lancement, lecture des lignes, captures et entrée en mode courses.
// XCTestCase est nonisolated : on sort de l'isolation MainActor par défaut.
nonisolated class ParcoursesUITestCase: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func launch(reset: Bool, launchArguments: [String] = [], dark: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
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
  @MainActor
  func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    var swipes = 0
    while !(element.waitForExistence(timeout: swipes == 0 ? 15 : 2) && element.isHittable) && swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(element.exists && element.isHittable, "élément introuvable après défilement", file: file, line: line)
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
  @MainActor
  func enterShopping(
    confidenceQ: Int?, items: [String], launchArguments: [String] = [], dark: Bool = false,
    atPicker: (XCUIApplication) -> Void = { _ in }
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-shopping"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    app.launchEnvironment["PARCOURSES_TEST_SEED_STORE"] = "Leclerc Auch"
    app.launchEnvironment["PARCOURSES_TEST_UNDO_SECONDS"] = "60"
    if let confidenceQ {
      app.launchEnvironment["PARCOURSES_TEST_SEED_SNAPSHOT"] = Self.snapshot(confidenceQ: confidenceQ)
    }
    app.launchArguments += launchArguments
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
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
