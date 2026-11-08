import XCTest

/// Audit d'accessibilité automatique (`performAccessibilityAudit`, iOS 17+) de chaque écran principal, à la taille
/// de texte par défaut, en `AccessibilityXXXL` (AX5) et en mode sombre. Exécuté avec le reste des tests UI en CI.
///
/// Toutes les catégories d'audit sont actives (`.all`). Les exceptions sont filtrées au cas par cas dans
/// `isKnownIssue`, chacune bornée à des éléments ou à une situation précise et justifiée.
nonisolated final class ParcoursesAccessibilityUITests: ParcoursesUITestCase {
  /// Tous les problèmes d'un parcours sont listés d'un coup : on ne s'arrête pas au premier échec.
  override func setUp() {
    continueAfterFailure = true
  }

  /// AX5 : la plus grande taille de Dynamic Type.
  private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  /// Éléments du dock (saisie, « Terminer », bannière « Annuler », suggestions) : ils restent audités.
  private static let dockIdentifiers: Set<String> = [
    "quickEntry", "shoppingEntry", "finish", "undo", "undoMessage", "allChecked", "suggestion", "addItem",
  ]

  /// Exceptions documentées. Retourne vrai pour ignorer le problème.
  @MainActor
  private static func isKnownIssue(_ issue: XCUIAccessibilityAuditIssue, app: XCUIApplication, modal: Bool) -> Bool {
    let keyboard = app.keyboards.firstMatch
    let keyboardIsShown = keyboard.exists
    // 1. « Contrast nearly passed » : résultat limite, mesuré sur le rendu du système (boutons Liquid Glass,
    //    gris sémantiques des en-têtes de section). Les « Contrast failed » restent bloquants.
    if issue.auditType == .contrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
      return true
    }
    guard let element = issue.element else {
      guard issue.auditType == .contrast || issue.auditType == .textClipped else { return false }
      // 2. Contraste ou texte rogné sans élément localisé, clavier ouvert : l'audit mesure les pixels du clavier
      //    translucide et du contenu qui défile dessous, sans dire lequel (constaté sur iOS 18).
      if keyboardIsShown { return true }
      // 2 bis. Sans clavier : seulement si une ligne de la liste est coupée par le bord du dock. L'audit mesure
      //    alors le liseré de texte encore visible et ne sait pas localiser la ligne (constaté en AX5, où les
      //    lignes débordent). Sans ligne coupée, le problème reste bloquant.
      return lineIsCutByDock(app)
    }
    let frame = element.frame
    switch issue.auditType {
    case .dynamicType:
      // 3. Écrans présentés en modal (feuilles, plein écran du mode courses) : l'audit change la taille du texte à
      //    chaud sur la fenêtre, et ce changement n'atteint pas les contrôleurs présentés (« User will not be able
      //    to change the font size »), y compris pour un simple `Text`. La tenue du texte y est vérifiée par les
      //    parcours lancés en AX5, dont les captures sont jointes.
      if modal { return true }
      // 3 bis. Boutons de la barre de navigation : le système les plafonne et leur substitue la visionneuse de grand
      //    contenu (appui long), comme le recommandent les HIG.
      if app.navigationBars.firstMatch.exists, app.navigationBars.firstMatch.frame.intersects(frame) { return true }
      // 4. Textes statiques des composants système (en-têtes et pieds de section, `ContentUnavailableView`,
      //    `DisclosureGroup`) signalés « partially unsupported » alors qu'ils suivent Dynamic Type : les
      //    captures AX5 jointes le montrent. Nos boutons et champs restent audités.
      return element.elementType == .staticText && !dockIdentifiers.contains(element.identifier)
    case .sufficientElementDescription:
      // 5. Barre de suggestions du clavier système (boutons sans description), 44 pt au-dessus du clavier.
      return keyboardIsShown && keyboard.frame.insetBy(dx: 0, dy: -50).intersects(frame)
    case .contrast, .textClipped:
      // 6. Contenu de la liste sous le clavier ou sous le dock translucide : l'audit mesure des pixels mélangés au
      //    fond, ou un texte que le dock recouvre. Le dock lui-même reste audité.
      if keyboardIsShown && keyboard.frame.intersects(frame) { return true }
      if !dockIdentifiers.contains(element.identifier), let top = dockTop(app), frame.maxY > top { return true }
      // 7. Lignes passées sous la barre de navigation en défilant (cadre hors écran).
      if frame.minY < 0 { return true }
      // 8. Feuille « articles restants » à détente `.medium` : le système la met à l'échelle pendant sa
      //    présentation, les cadres fractionnaires faussent la mesure. Les captures montrent un texte entier.
      if app.buttons["keepRemaining"].exists && frame.origin.x.truncatingRemainder(dividingBy: 1) != 0 {
        return true
      }
      // 9. Champs de texte : l'audit signale le texte « rogné » des `UITextField` SwiftUI au repos et à la taille
      //    par défaut ; les captures montrent le texte et l'indication entiers.
      return issue.auditType == .textClipped && element.elementType == .textField
    default:
      return false
    }
  }

  /// Vrai si une cellule de liste chevauche le haut du dock.
  @MainActor
  private static func lineIsCutByDock(_ app: XCUIApplication) -> Bool {
    guard let top = dockTop(app) else { return false }
    return app.cells.allElementsBoundByIndex.contains { $0.frame.minY < top && $0.frame.maxY > top }
  }

  /// Haut du dock : le plus haut de ses éléments présents, moins sa marge.
  @MainActor
  private static func dockTop(_ app: XCUIApplication) -> CGFloat? {
    let tops = ["quickEntry", "shoppingEntry", "undoMessage", "allChecked"].compactMap { id -> CGFloat? in
      let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
      return element.exists ? element.frame.minY : nil
    }
    let suggestion = app.buttons.matching(identifier: "suggestion").firstMatch
    let all = tops + (suggestion.exists ? [suggestion.frame.minY] : [])
    // Sans clavier ni dock (écran Listes) : pas de zone exclue.
    return all.min().map { $0 - 8 }
  }

  /// Audit complet d'un écran. Les problèmes sont réunis puis consignés après l'audit, pas depuis son gestionnaire :
  /// consigner un échec à l'intérieur du gestionnaire bloque l'audit (constaté sur Xcode 26/27, simulateurs
  /// iOS 26.5 et 27.0 : le test dépasse son délai).
  @MainActor
  private func audit(
    _ app: XCUIApplication, _ screen: String, modal: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) {
    // Les feuilles s'animent à l'arrivée : l'audit lit les cadres pendant la transition sinon.
    Thread.sleep(forTimeInterval: 1)
    capture(app, "audit-\(screen)")
    var problems: [String] = []
    do {
      try app.performAccessibilityAudit(for: .all) { issue in
        if Self.isKnownIssue(issue, app: app, modal: modal) { return true }
        // `String(describing:)` : lire `label` résoudrait l'élément pendant l'audit, ce qui le bloque.
        let keyboard = app.keyboards.firstMatch
        let keyboardInfo = keyboard.exists ? "\(keyboard.frame)" : "aucun"
        let element =
          issue.element.map { "\($0.elementType.rawValue) \($0.identifier) \($0.frame) clavier \(keyboardInfo)" }
          ?? "écran"
        problems.append("\(issue.auditType): \(issue.compactDescription) [\(element)] — \(issue.detailedDescription)")
        return true
      }
    } catch {
      XCTFail("Audit d'accessibilité « \(screen) » impossible : \(error)")
    }
    // Journal : lisible dans la sortie de xcodebuild même si la consignation de l'échec est lente.
    for problem in problems { NSLog("AUDIT[\(screen)] \(problem)") }
    guard !problems.isEmpty else { return }
    // Échec consigné sans pile d'appels : la symbolication de la pile bloque parfois XCTest en local (constaté
    // sur Xcode 26, le test dépasse alors son délai). L'emplacement suffit.
    let context = XCTSourceCodeContext(
      callStackAddresses: [], location: XCTSourceCodeLocation(filePath: String(describing: file), lineNumber: Int(line))
    )
    record(
      XCTIssue(
        type: .assertionFailure,
        compactDescription: "Audit d'accessibilité « \(screen) » :\n" + problems.joined(separator: "\n"),
        sourceCodeContext: context))
  }

  /// Écrans Listes (vide, puis remplie), Liste, À propos.
  @MainActor
  private func auditLists(arguments: [String], suffix: String, dark: Bool = false) {
    let app = launch(reset: true, launchArguments: arguments, dark: dark)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    audit(app, "listes-vide\(suffix)")

    app.buttons["Nouvelle liste"].tap()
    let name = app.alerts.textFields.firstMatch
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.typeText("Semaine")
    app.alerts.buttons["Créer"].tap()

    let entry = app.textFields["quickEntry"]
    XCTAssertTrue(entry.waitForExistence(timeout: 5))
    audit(app, "liste-vide\(suffix)")
    for text in ["2 laits demi-écrémé", "tomates", "xyzzy"] {
      if !entry.hasFocus { entry.tap() }
      entry.typeText(text + "\n")
    }
    XCTAssertTrue(row(app, "laits demi-écrémé, 2", "non coché").waitForExistence(timeout: 5))
    row(app, "tomates", "non coché").tap()
    XCTAssertTrue(row(app, "tomates", "coché").waitForExistence(timeout: 5))
    audit(app, "liste-remplie\(suffix)")

    app.navigationBars.buttons.firstMatch.tap()
    XCTAssertTrue(app.buttons["about"].waitForExistence(timeout: 5))
    audit(app, "listes\(suffix)")
  }

  @MainActor
  func testAuditLists() {
    auditLists(arguments: [], suffix: "")
  }

  @MainActor
  func testAuditListsAX5() {
    auditLists(arguments: Self.ax5, suffix: "-ax5")
  }

  @MainActor
  func testAuditAbout() {
    let app = launch(reset: true)
    XCTAssertTrue(app.staticTexts["Aucune liste"].waitForExistence(timeout: 15))
    openAbout(app)
    XCTAssertTrue(
      app.links["aboutOSMLink"].exists || app.buttons["aboutOSMLink"].exists
        || app.staticTexts["Données cartographiques"].exists)
    audit(app, "a-propos", modal: true)
  }

  @MainActor
  private func openAbout(_ app: XCUIApplication) {
    let about = app.buttons["about"]
    XCTAssertTrue(about.waitForExistence(timeout: 5))
    about.tap()
    XCTAssertTrue(app.navigationBars["À propos"].waitForExistence(timeout: 5))
  }

  /// Choix du magasin, mode courses, feuille « articles restants » et résumé.
  @MainActor
  private func auditShopping(arguments: [String], suffix: String, dark: Bool = false) {
    let app = enterShopping(
      confidenceQ: nil, items: ["2 laits", "tomates", "yaourts bio", "xyzzy"], launchArguments: arguments, dark: dark
    ) { app in
      self.audit(app, "choix-magasin\(suffix)", modal: true)
    }
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 5))
    audit(app, "mode-courses\(suffix)", modal: true)

    let tomatoes = row(app, "tomates", "non coché")
    reveal(tomatoes, in: app)
    tomatoes.tap()
    XCTAssertTrue(app.buttons["undo"].waitForExistence(timeout: 3))
    audit(app, "mode-courses-annuler\(suffix)", modal: true)

    reveal(app.buttons["finish"], in: app)
    app.buttons["finish"].tap()
    XCTAssertTrue(app.buttons["keepRemaining"].waitForExistence(timeout: 5))
    audit(app, "articles-restants\(suffix)", modal: true)
    app.buttons["keepRemaining"].tap()
    XCTAssertTrue(app.buttons["closeSummary"].waitForExistence(timeout: 5))
    audit(app, "resume\(suffix)", modal: true)
  }

  @MainActor
  func testAuditShopping() {
    auditShopping(arguments: [], suffix: "")
  }

  @MainActor
  func testAuditShoppingAX5() {
    auditShopping(arguments: Self.ax5, suffix: "-ax5")
  }

  /// Mode sombre : teinte, fonds opaques et textes secondaires sur fond sombre.
  @MainActor
  func testAuditListsDark() {
    auditLists(arguments: [], suffix: "-sombre", dark: true)
  }

  @MainActor
  func testAuditShoppingDark() {
    auditShopping(arguments: [], suffix: "-sombre", dark: true)
  }
}
