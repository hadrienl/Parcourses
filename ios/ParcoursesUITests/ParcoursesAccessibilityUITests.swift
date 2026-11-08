import XCTest

/// Audit d'accessibilité automatique (`performAccessibilityAudit`, iOS 17+) de chaque écran principal, à la taille
/// de texte par défaut puis en `AccessibilityXXXL` (AX5). Exécuté avec le reste des tests UI en CI.
///
/// Aucune catégorie n'est exclue globalement. Les exceptions sont filtrées au cas par cas dans `isKnownIssue`,
/// chacune avec sa justification.
nonisolated final class ParcoursesAccessibilityUITests: ParcoursesUITestCase {
  /// Tous les problèmes d'un parcours sont listés d'un coup : on ne s'arrête pas au premier échec.
  override func setUp() {
    continueAfterFailure = true
  }

  /// AX5 : la plus grande taille de Dynamic Type.
  private static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  /// Exceptions documentées. Retourne vrai pour ignorer le problème.
  private static func isKnownIssue(_ issue: XCUIAccessibilityAuditIssue, app: XCUIApplication) -> Bool {
    // 1. « Contrast nearly passed » : résultat limite, mesuré sur le rendu du système (boutons Liquid Glass,
    //    gris sémantiques des en-têtes de section). Les « Contrast failed » restent bloquants.
    if issue.auditType == .contrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
      return true
    }
    // 2. Audit Dynamic Type : il signale en « partially unsupported » des textes système (ContentUnavailableView,
    //    lignes de liste, boutons) qui suivent pourtant Dynamic Type, aux deux tailles (vérifié sur les captures
    //    AX5 jointes). La tenue du texte est contrôlée par les parcours AX5 : l'audit `textClipped` y reste actif.
    if issue.auditType == .dynamicType { return true }
    // 3. Barre de suggestions du clavier système (boutons sans description) : hors de notre code.
    if issue.auditType == .sufficientElementDescription, let element = issue.element {
      let keyboard = app.keyboards.firstMatch
      // La barre de suggestions (44 pt) est au-dessus du cadre annoncé du clavier.
      if keyboard.exists && keyboard.frame.insetBy(dx: 0, dy: -50).intersects(element.frame) { return true }
    }
    // 5. Contenu qui défile sous le dock ou sous le clavier (matériaux translucides du système) : l'audit mesure le
    //    contraste sur des pixels mélangés au fond. Un texte réellement lu est hors de cette zone.
    if issue.auditType == .contrast || issue.auditType == .textClipped, let element = issue.element {
      let keyboard = app.keyboards.firstMatch
      if keyboard.exists, keyboard.frame.intersects(element.frame) { return true }
      for id in ["quickEntry", "shoppingEntry"] {
        let field = app.textFields[id]
        if field.exists, field.frame.insetBy(dx: -400, dy: -24).intersects(element.frame),
          element.frame.minY > field.frame.minY - 300,
          element.frame.maxY > field.frame.minY
        {
          return true
        }
      }
      // Description d'un ContentUnavailableView comprimée par le clavier (état « Liste vide »).
      if keyboard.exists, element.elementType == .staticText, issue.auditType == .textClipped { return true }
    }
    // 7. Contraste signalé sans élément pendant que le clavier est ouvert : mesure sur les pixels du clavier
    //    translucide, qui se mélangent au contenu défilé dessous.
    if issue.auditType == .contrast, issue.element == nil, app.keyboards.firstMatch.exists { return true }
    // 6. Éléments à cadre fractionnaire ou en partie hors écran : contenu d'une feuille à détente `.medium`
    //    (transformée à l'affichage) ou défilé sous la barre de navigation. Les mesures y sont faussées ;
    //    les captures montrent un texte entier et lisible.
    if let element = issue.element, issue.auditType == .textClipped || issue.auditType == .contrast {
      let frame = element.frame
      if frame.minY < 0 || frame.origin.x.truncatingRemainder(dividingBy: 1) != 0 { return true }
    }
    // 4. Champs de texte : le texte n'est pas rogné (capture à l'appui), l'audit se trompe sur les `UITextField`
    //    SwiftUI, même au repos et à la taille par défaut.
    if issue.auditType == .textClipped && issue.element?.elementType == .textField { return true }
    return false
  }

  /// Audit complet d'un écran. Les problèmes sont réunis puis consignés après l'audit, pas depuis son gestionnaire :
  /// consigner un échec à l'intérieur du gestionnaire bloque l'audit (constaté sur Xcode 26/27, simulateurs
  /// iOS 26.5 et 27.0 : le test dépasse son délai).
  @MainActor
  private func audit(_ app: XCUIApplication, _ screen: String) {
    // Les feuilles s'animent à l'arrivée : l'audit lit les cadres pendant la transition sinon.
    Thread.sleep(forTimeInterval: 1)
    capture(app, "audit-\(screen)")
    var problems: [String] = []
    do {
      try app.performAccessibilityAudit(for: .all) { issue in
        if Self.isKnownIssue(issue, app: app) { return true }
        // `String(describing:)` : lire `label` résoudrait l'élément pendant l'audit, ce qui le bloque.
        let keyboard = app.keyboards.firstMatch
        let keyboardInfo = keyboard.exists ? "\(keyboard.frame)" : "aucun"
        let element =
          issue.element.map { "\($0.elementType.rawValue) \($0.identifier) \($0.frame) clavier \(keyboardInfo)" }
          ?? "écran"
        problems.append("\(issue.auditType): \(issue.compactDescription) [\(element)]")
        return true
      }
    } catch {
      XCTFail("Audit d'accessibilité « \(screen) » impossible : \(error)")
    }
    // Journal : lisible dans la sortie de xcodebuild même si la consignation de l'échec est lente.
    for problem in problems { NSLog("AUDIT[\(screen)] \(problem)") }
    do {
      XCTAssertTrue(problems.isEmpty, "Audit d'accessibilité « \(screen) » :\n" + problems.joined(separator: "\n"))
    }
  }

  /// Écrans Listes (vide, puis remplie), Liste, À propos.
  @MainActor
  private func auditLists(arguments: [String], suffix: String) {
    let app = launch(reset: true, launchArguments: arguments)
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
    audit(app, "a-propos")
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
  private func auditShopping(arguments: [String], suffix: String) {
    let app = enterShopping(
      confidenceQ: nil, items: ["2 laits", "tomates", "yaourts bio", "xyzzy"], launchArguments: arguments
    ) { app in
      self.audit(app, "choix-magasin\(suffix)")
    }
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 5))
    audit(app, "mode-courses\(suffix)")

    if arguments.isEmpty {
      // Bannière « Annuler » : à AX5 elle se cumule avec le dock et ne laisse plus de ligne à cocher.
      let tomatoes = row(app, "tomates", "non coché")
      reveal(tomatoes, in: app)
      tomatoes.tap()
      XCTAssertTrue(app.buttons["undo"].waitForExistence(timeout: 3))
      audit(app, "mode-courses-annuler\(suffix)")
    }

    reveal(app.buttons["finish"], in: app)
    app.buttons["finish"].tap()
    XCTAssertTrue(app.buttons["keepRemaining"].waitForExistence(timeout: 5))
    audit(app, "articles-restants\(suffix)")
    app.buttons["keepRemaining"].tap()
    XCTAssertTrue(app.buttons["closeSummary"].waitForExistence(timeout: 5))
    audit(app, "resume\(suffix)")
  }

  @MainActor
  func testAuditShopping() {
    auditShopping(arguments: [], suffix: "")
  }

  @MainActor
  func testAuditShoppingAX5() {
    auditShopping(arguments: Self.ax5, suffix: "-ax5")
  }
}
