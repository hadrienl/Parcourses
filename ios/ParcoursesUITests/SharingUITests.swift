import XCTest

/// Partage d'une liste (#87, lot 87.4), sur le serveur en mémoire de `UITestSharingGateway` : feuille « Partager »,
/// carte d'invitation, lecture seule, en clair, en sombre et en texte agrandi. Les captures (`sharing-…`) servent à la
/// PR (`xcrun xcresulttool export attachments`).
nonisolated final class SharingUITests: ParcoursesUITestCase {
  /// AX3 : assez grand pour empiler les contrôles, lisible dans une capture.
  private static let largeText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]

  @MainActor
  private func launch(_ scenario: String, dark: Bool = false, largeText: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PARCOURSES_TEST_SHARING"] = scenario
    app.launchEnvironment["PARCOURSES_TEST_STORE"] = "uitests-sharing"
    app.launchEnvironment["PARCOURSES_TEST_STORE_RESET"] = "1"
    if dark { app.launchEnvironment["PARCOURSES_TEST_COLOR_SCHEME"] = "dark" }
    if largeText { app.launchArguments += Self.largeText }
    app.launch()
    return app
  }

  /// Ligne de la liste partagée dans Mes listes, une fois descendue.
  @MainActor
  private func openSharedList(_ app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Courses de la semaine")).firstMatch
    reveal(row, in: app)
    row.tap()
    XCTAssertTrue(app.descendants(matching: .any)["itemList"].waitForExistence(timeout: 10))
  }

  @MainActor
  private func suffix(dark: Bool, largeText: Bool) -> String {
    (dark ? "-sombre" : "-clair") + (largeText ? "-texte-agrandi" : "")
  }

  // MARK: - Propriétaire

  @MainActor
  func testOwnerSharesTheList() {
    runOwner(dark: false, largeText: false)
  }

  @MainActor
  func testOwnerSharesTheListDark() {
    runOwner(dark: true, largeText: false)
  }

  @MainActor
  func testShareSheetWithLargeText() {
    runOwner(dark: false, largeText: true)
  }

  @MainActor
  private func runOwner(dark: Bool, largeText: Bool) {
    let app = launch("owner", dark: dark, largeText: largeText)
    let name = suffix(dark: dark, largeText: largeText)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Courses de la semaine")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(row.label.contains("partagée avec Léa et Tom"), row.label)
    capture(app, "sharing-1-mes-listes\(name)")
    openSharedList(app)

    // Pastilles des autres membres dans la barre : « Membres : Léa, Tom et vous. Partager la liste ».
    let members = app.buttons["listMembers"]
    XCTAssertTrue(members.waitForExistence(timeout: 10))
    XCTAssertEqual(members.label, "Membres : Léa, Tom et vous. Partager la liste")
    XCTAssertTrue(app.descendants(matching: .any)["lastChange"].waitForExistence(timeout: 5))
    // Article modifié par Léa : « dernière modification par Léa » dans le libellé lu.
    let butter = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "Beurre doux, 1, dernière modification par Léa")).firstMatch
    XCTAssertTrue(butter.waitForExistence(timeout: 5))
    capture(app, "sharing-2-liste-partagee\(name)")

    members.tap()
    let field = app.textFields["shareEmailField"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let leaRow = app.buttons["member-Léa"]
    XCTAssertTrue(leaRow.waitForExistence(timeout: 5))
    capture(app, "sharing-3-partager\(name)")

    // Déjà membre : erreur liée au champ.
    field.tap()
    field.typeText("lea@exemple.fr")
    app.buttons["sendInvitation"].tap()
    let error = app.descendants(matching: .any)["shareError"]
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertTrue(error.label.contains("fait déjà partie de la liste"), error.label)
    capture(app, "sharing-4-erreur\(name)")

    // Invitation envoyée : champ vidé, capsule, nouvelle invitation en attente.
    field.tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "camille@exemple.fr")
    app.buttons["sendInvitation"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["sharingToast"].waitForExistence(timeout: 5))
    let actions = app.buttons["invitationActions-camille@exemple.fr"]
    reveal(actions, in: app)
    capture(app, "sharing-5-invitations\(name)")

    // Gestion d'un membre : menu avec l'accès et « Retirer de la liste ».
    reveal(leaRow, in: app)
    leaRow.tap()
    XCTAssertTrue(app.buttons["Retirer de la liste"].waitForExistence(timeout: 5))
    capture(app, "sharing-6-membre\(name)")
  }

  // MARK: - Lecteur

  @MainActor
  func testViewerSeesAReadOnlyList() {
    runViewer(dark: false, largeText: false)
  }

  @MainActor
  func testViewerSeesAReadOnlyListDarkWithLargeText() {
    runViewer(dark: true, largeText: true)
  }

  @MainActor
  private func runViewer(dark: Bool, largeText: Bool) {
    let app = launch("viewer", dark: dark, largeText: largeText)
    let name = suffix(dark: dark, largeText: largeText)
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Courses de la semaine")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 15))
    XCTAssertTrue(row.label.contains("lecture seule"), row.label)
    openSharedList(app)
    // Ni saisie, ni coche, ni mode courses : la note du bas le dit.
    let note = app.descendants(matching: .any)["readOnlyNote"]
    XCTAssertTrue(note.waitForExistence(timeout: 10))
    XCTAssertTrue(note.label.contains("Demandez à Hadrien"), note.label)
    XCTAssertFalse(app.textFields["quickEntry"].exists)
    XCTAssertFalse(app.buttons["startShopping"].exists)
    XCTAssertEqual(app.buttons["listMembers"].label, "Membres : Hadrien, Léa et vous. Voir les membres")
    capture(app, "sharing-7-lecture-seule\(name)")

    // Le bouton des membres ouvre « Membres », avec « Quitter la liste ».
    app.buttons["listMembers"].tap()
    let leave = app.buttons["leaveList"]
    reveal(leave, in: app)
    capture(app, "sharing-8-membres\(name)")
  }

  // MARK: - Invitation reçue

  @MainActor
  func testAnInvitationIsAcceptedFromMyLists() {
    runInvitation(dark: false, largeText: false)
  }

  @MainActor
  func testAnInvitationCardDarkWithLargeText() {
    runInvitation(dark: true, largeText: true)
  }

  @MainActor
  private func runInvitation(dark: Bool, largeText: Bool) {
    let app = launch("invitation", dark: dark, largeText: largeText)
    let name = suffix(dark: dark, largeText: largeText)
    let card = app.descendants(matching: .any)["invitationCard"]
    XCTAssertTrue(card.waitForExistence(timeout: 15))
    XCTAssertTrue(card.label.hasPrefix("Invitation. Hadrien vous invite à"), card.label)
    capture(app, "sharing-9-invitation\(name)")
    let accept = app.buttons["acceptInvitation"]
    reveal(accept, in: app)
    accept.tap()
    // Acceptée : la liste descend puis s'ouvre.
    XCTAssertTrue(app.descendants(matching: .any)["itemList"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["listMembers"].waitForExistence(timeout: 10))
    capture(app, "sharing-10-liste-rejointe\(name)")
  }
}
