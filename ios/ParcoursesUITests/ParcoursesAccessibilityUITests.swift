import XCTest

/// Audit d'accessibilité automatique (`performAccessibilityAudit`, iOS 17+) de chaque écran principal, à la taille
/// de texte par défaut, en `AccessibilityXXXL` (AX5), en mode sombre, avec Contraste augmenté et avec Réduire la
/// transparence. Exécuté avec le reste des tests UI en CI.
///
/// Toutes les catégories d'audit sont actives (`.all`). Les exceptions sont filtrées au cas par cas dans
/// `exception(for:screen:)`, chacune bornée à des éléments ou à une situation précise et justifiée, et journalisées
/// (`AUDIT-EXCEPTION[écran]`) avec leur règle.
nonisolated final class ParcoursesAccessibilityUITests: ParcoursesUITestCase {
  /// Tous les problèmes d'un parcours sont listés d'un coup : on ne s'arrête pas au premier échec.
  override func setUp() {
    continueAfterFailure = true
  }

  /// AX5 : la plus grande taille de Dynamic Type.
  fileprivate static let ax5 = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

  /// Éléments du dock (saisie, « Terminer », bannière « Annuler », suggestions) : ils restent audités.
  private static let dockIdentifiers: Set<String> = [
    "quickEntry", "shoppingEntry", "finish", "undo", "undoMessage", "allChecked", "suggestion", "addItem",
  ]

  /// État de l'écran relevé avant l'audit : le gestionnaire ne fait plus de requêtes XCUI, qui ralentissent l'audit
  /// au point de dépasser son délai sur les machines de CI.
  private struct Screen {
    let modal: Bool
    /// Parcours lancé en AX5 : le texte est déjà à sa plus grande taille, l'audit le mesure tel qu'il est affiché.
    let launchedAtLargestSize: Bool
    let keyboard: CGRect?
    let navigationBar: CGRect?
    /// Haut du dock au premier plan. `nil` quand une feuille le recouvre : tout le contenu de la feuille est audité.
    let dockTop: CGFloat?
    /// Lignes de la liste au premier plan que le haut du dock coupe.
    let linesCutByDock: Int
    let sheetIsShown: Bool
    /// Bas de l'écran.
    let bottom: CGFloat

    @MainActor
    init(_ app: XCUIApplication, modal: Bool) {
      self.modal = modal
      launchedAtLargestSize = app.launchArguments.contains(ParcoursesAccessibilityUITests.ax5[1])
      let keyboard = app.keyboards.firstMatch
      self.keyboard = keyboard.exists ? keyboard.frame : nil
      let bar = app.navigationBars.firstMatch
      navigationBar = bar.exists ? bar.frame : nil
      let top = ParcoursesAccessibilityUITests.dockTop(app)
      dockTop = top
      linesCutByDock = top.map { ParcoursesAccessibilityUITests.linesCut(at: $0, in: app) } ?? 0
      sheetIsShown = app.buttons["keepRemaining"].exists
      bottom = app.windows.firstMatch.frame.maxY
    }
  }

  /// Exception retenue pour un problème : sa raison, journalisée.
  private enum Exception {
    /// Problème ignoré, avec sa raison.
    case known(String)
    /// Problème non localisé imputé à une ligne coupée par le dock : décompté sur le quota de l'écran.
    case cutLine
  }

  /// Problèmes non localisés admis par ligne coupée par le dock : le liseré visible de la ligne, mesuré par le
  /// contraste et par le texte rogné. Au-delà, le problème est bloquant. Dans une liste à une colonne, une seule
  /// ligne chevauche le haut du dock : le quota de l'écran est donc de 0 ou 2 (constaté : 1 à 2 sur iOS 18.6 en AX5).
  private static let issuesPerCutLine = 2

  /// Exceptions documentées. Retourne `nil` pour un problème bloquant.
  @MainActor
  private static func exception(for issue: XCUIAccessibilityAuditIssue, screen: Screen) -> Exception? {
    let keyboardIsShown = screen.keyboard != nil
    // 1. « Contrast nearly passed » : résultat limite, mesuré sur le rendu du système (boutons Liquid Glass,
    //    gris sémantiques des en-têtes de section). Les « Contrast failed » restent bloquants.
    if issue.auditType == .contrast && issue.compactDescription.localizedCaseInsensitiveContains("nearly") {
      return .known("1 contraste limite")
    }
    guard let element = issue.element else {
      // Problèmes sans élément localisé (iOS 18 surtout, qui ne relie pas le nœud SwiftUI à un élément XCUI).
      // 2. Écran présenté en modal : même cause qu'en 3 ci-dessous, la taille de texte changée à chaud n'atteint
      //    pas le contrôleur présenté (« unsupported »). Le texte rogné, lui, n'est ignoré qu'à la taille par
      //    défaut (« may be clipped at larger Dynamic Type sizes ») : les parcours lancés en AX5 le mesurent au
      //    rendu réel, sans changement à chaud, et l'auditent.
      if screen.modal && issue.auditType == .dynamicType { return .known("2 Dynamic Type à chaud en modal") }
      if screen.modal && issue.auditType == .textClipped && !screen.launchedAtLargestSize {
        return .known("2 texte rogné à chaud en modal")
      }
      // 2 bis. Clavier ouvert : textes du clavier système (barre de suggestions, autre processus), qui ne suivent
      //    pas Dynamic Type, et pixels du clavier translucide pour le contraste (constaté sur iOS 18 : le nombre
      //    de problèmes suit le nombre de suggestions affichées).
      let keyboardIssue = [.dynamicType, .contrast, .textClipped].contains(issue.auditType)
      if keyboardIsShown && keyboardIssue { return .known("2 bis clavier") }
      guard issue.auditType == .contrast || issue.auditType == .textClipped else { return nil }
      // 2 ter. Sans clavier : seulement si une ligne de la liste au premier plan est coupée par le bord du dock.
      //    L'audit mesure alors le liseré de texte encore visible et ne sait pas localiser la ligne (constaté en
      //    AX5, où les lignes débordent). Quota de `issuesPerCutLine` par ligne coupée : au-delà, ou sans ligne
      //    coupée, le problème reste bloquant.
      return screen.linesCutByDock > 0 ? .cutLine : nil
    }
    let frame = element.frame
    switch issue.auditType {
    case .dynamicType:
      // 3. Écrans présentés en modal (feuilles, plein écran du mode courses) : l'audit change la taille du texte à
      //    chaud sur la fenêtre, et ce changement n'atteint pas les contrôleurs présentés (« User will not be able
      //    to change the font size »), y compris pour un simple `Text`. La tenue du texte y est vérifiée par les
      //    parcours lancés en AX5 (texte rogné audité, captures jointes).
      if screen.modal { return .known("3 Dynamic Type à chaud en modal") }
      // 3 bis. Boutons de la barre de navigation : le système les plafonne et leur substitue la visionneuse de grand
      //    contenu (appui long), comme le recommandent les HIG.
      if let bar = screen.navigationBar, bar.intersects(frame) { return .known("3 bis barre de navigation") }
      // Tous les autres textes, `EmptyState` et en-têtes de section compris, sont audités.
      return nil
    case .sufficientElementDescription:
      // 5. Barre de suggestions du clavier système (boutons sans description), 44 pt au-dessus du clavier.
      let inSuggestionBar = screen.keyboard?.insetBy(dx: 0, dy: -50).intersects(frame) ?? false
      return inSuggestionBar ? .known("5 suggestions du clavier") : nil
    case .contrast, .textClipped:
      // 6. Contenu de la liste sous le clavier ou sous le dock opaque : l'audit mesure des pixels mélangés au
      //    fond, ou un texte que le dock recouvre. Le dock lui-même reste audité, et rien n'est exclu quand une
      //    feuille recouvre le dock.
      if screen.keyboard?.intersects(frame) ?? false { return .known("6 sous le clavier") }
      if !dockIdentifiers.contains(element.identifier), let top = screen.dockTop, frame.maxY > top {
        return .known("6 sous le dock")
      }
      // 7. Éléments à cheval sur le bord de l'écran : lignes passées sous la barre de navigation en défilant, ou bas
      //    d'une feuille qui défile (« articles restants » en AX5 sur iPhone 11). L'audit mesure la partie visible,
      //    coupée par le bord ; l'élément se lit entier une fois amené à l'écran.
      if frame.minY < 0 { return .known("7 hors de l'écran en haut") }
      if frame.maxY > screen.bottom { return .known("7 hors de l'écran en bas") }
      // 8. Feuille « articles restants » à détente `.medium` : le système la met à l'échelle, les cadres
      //    fractionnaires faussent la mesure du texte rogné. Les captures montrent un texte entier. Le contraste
      //    de la feuille reste audité.
      if issue.auditType == .textClipped && screen.sheetIsShown
        && frame.origin.x.truncatingRemainder(dividingBy: 1) != 0
      {
        return .known("8 feuille mise à l'échelle")
      }
      // 9. Champs de texte : l'audit signale le texte « rogné » des `UITextField` SwiftUI au repos, à la taille par
      //    défaut comme en AX5 (`quickEntry`, `shoppingEntry`, `storeSearch`) ; les captures montrent le texte et
      //    l'indication entiers.
      if issue.auditType == .textClipped && element.elementType == .textField { return .known("9 champ de texte") }
      return nil
    default:
      return nil
    }
  }

  /// Haut du dock : le plus haut de ses éléments au premier plan, moins sa marge. Un élément recouvert par une
  /// feuille n'est pas « hittable » : sans élément au premier plan, aucune zone n'est exclue.
  @MainActor
  fileprivate static func dockTop(_ app: XCUIApplication) -> CGFloat? {
    let candidates =
      ["quickEntry", "shoppingEntry", "undoMessage", "allChecked"].map {
        app.descendants(matching: .any).matching(identifier: $0).firstMatch
      } + [app.buttons.matching(identifier: "suggestion").firstMatch]
    let tops = candidates.compactMap { element -> CGFloat? in
      element.exists && element.isHittable ? element.frame.minY : nil
    }
    // Sans clavier ni dock (écran Listes) : pas de zone exclue.
    return tops.min().map { $0 - 8 }
  }

  /// Lignes de la liste au premier plan coupées par le haut du dock. La liste recouverte (l'écran Liste sous le
  /// plein écran du mode courses) reste dans l'arbre d'accessibilité, et `isHittable` ne les distingue pas (constaté
  /// en AX5 sur iPhone 11 : aucune des deux ne l'est) : la liste est celle du dock au premier plan, par identifiant.
  @MainActor
  fileprivate static func linesCut(at top: CGFloat, in app: XCUIApplication) -> Int {
    let shoppingEntry = app.textFields["shoppingEntry"]
    let id = shoppingEntry.exists && shoppingEntry.isHittable ? "shoppingList" : "itemList"
    let list = app.collectionViews[id]
    guard list.exists else { return 0 }
    return list.cells.allElementsBoundByIndex.filter { $0.frame.minY < top && $0.frame.maxY > top }.count
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
    let state = Screen(app, modal: modal)
    var problems: [String] = []
    var exceptions: [String] = []
    // Un audit qui dépasse son délai (machines de CI chargées) est relancé une fois.
    for attempt in 1...2 {
      problems = []
      exceptions = []
      var cutLineQuota = state.linesCutByDock * Self.issuesPerCutLine
      do {
        try app.performAccessibilityAudit(for: .all) { issue in
          // Exception : journal sans l'élément, pour ne pas le résoudre une fois de plus pendant l'audit.
          let summary = "\(issue.auditType): \(issue.compactDescription)"
          switch Self.exception(for: issue, screen: state) {
          case .known(let reason):
            exceptions.append("\(reason) — \(summary)")
            return true
          case .cutLine where cutLineQuota > 0:
            cutLineQuota -= 1
            exceptions.append("2 ter ligne coupée par le dock — \(summary)")
            return true
          case .cutLine, nil:
            // Pas de `label` : le lire résoudrait l'élément pendant l'audit, ce qui le bloque.
            let element = issue.element.map { "\($0.elementType.rawValue) \($0.identifier) \($0.frame)" } ?? "écran"
            problems.append("\(summary) [\(element)] — \(issue.detailedDescription)")
            return true
          }
        }
        break
      } catch let error as NSError where error.code == -56 && attempt == 1 {
        NSLog("AUDIT[\(screen)] délai dépassé, nouvel essai")
      } catch {
        XCTFail("Audit d'accessibilité « \(screen) » impossible : \(error)")
      }
    }
    // Journal : lisible dans la sortie de xcodebuild même si la consignation de l'échec est lente. Les exceptions
    // y figurent aussi, avec leur règle, pour qu'une exception trop large se voie à la relecture.
    for problem in problems { NSLog("AUDIT[\(screen)] \(problem)") }
    for exception in exceptions { NSLog("AUDIT-EXCEPTION[\(screen)] \(exception)") }
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
  private func auditLists(
    arguments: [String], suffix: String, dark: Bool = false, settings: [String: String] = [:]
  ) {
    let app = launch(reset: true, launchArguments: arguments, dark: dark, settings: settings)
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
  private func auditShopping(
    arguments: [String], suffix: String, dark: Bool = false, settings: [String: String] = [:]
  ) {
    let app = enterShopping(
      confidenceQ: nil, items: ["2 laits", "tomates", "yaourts bio", "xyzzy"], launchArguments: arguments, dark: dark,
      settings: settings
    ) { app in
      self.audit(app, "choix-magasin\(suffix)", modal: true)
    }
    XCTAssertTrue(app.staticTexts["Vous tracez le premier trajet ici"].waitForExistence(timeout: 5))
    audit(app, "mode-courses\(suffix)", modal: true)

    let tomatoes = row(app, "tomates", "non coché")
    reveal(tomatoes, in: app, betweenBars: true)
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

  /// Contraste augmenté : variantes contrastées des couleurs système, texte secondaire en couleur principale.
  private static let increaseContrast = ["PARCOURSES_TEST_INCREASE_CONTRAST": "1"]

  /// Réduire la transparence : bannière « Annuler » et surimpressions sur fond opaque.
  private static let reduceTransparency = ["PARCOURSES_TEST_REDUCE_TRANSPARENCY": "1"]

  @MainActor
  func testAuditListsIncreasedContrast() {
    auditLists(arguments: [], suffix: "-contraste", settings: Self.increaseContrast)
  }

  @MainActor
  func testAuditShoppingIncreasedContrast() {
    auditShopping(arguments: [], suffix: "-contraste", settings: Self.increaseContrast)
  }

  /// Écrans du mode courses seulement : la bannière « Annuler » est le seul fond translucide maison.
  @MainActor
  func testAuditShoppingReducedTransparency() {
    auditShopping(arguments: [], suffix: "-transparence", settings: Self.reduceTransparency)
  }
}
