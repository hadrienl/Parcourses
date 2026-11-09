import Domain
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Parcourses

/// Habillage B3 « Ticket filé » (lot 9.11) : fil, lignes du ticket, rayons, jetons de couleur.
struct TicketThreadTests {
  @Test func threadIsTravelledUpToTheNextItem() {
    let places = ThreadPlace.places(count: 4, reached: 2, progress: true)
    #expect(places.map(\.reachesMarker) == [true, true, true, false])
    #expect(places.map(\.passesThrough) == [true, true, false, false])
    #expect(places.map(\.isFirst) == [true, false, false, false])
    #expect(places.map(\.isLast) == [false, false, false, true])
  }

  @Test func everythingIsTravelledWithoutANextItem() {
    let places = ThreadPlace.places(count: 3, reached: nil, progress: true)
    #expect(places.allSatisfy { $0.reachesMarker && $0.passesThrough })
  }

  /// Écran Liste : le fil est tracé, rien n'est parcouru.
  @Test func nothingIsTravelledWithoutProgress() {
    let places = ThreadPlace.places(count: 3, reached: nil, progress: false)
    #expect(places.allSatisfy { !$0.reachesMarker && !$0.passesThrough })
  }

  @Test func counterHasTwoDigits() {
    #expect(ShoppingView.counter(0) == "00")
    #expect(ShoppingView.counter(5) == "05")
    #expect(ShoppingView.counter(12) == "12")
  }
}

struct TicketLineTests {
  private func row(_ label: String, _ aisle: String) -> ShoppingRow {
    ShoppingRow(id: UUID(), label: label, quantity: nil, isChecked: false, aisleId: aisle)
  }

  /// Ordre appris : les rayons se posent sur le trajet sans rien déplacer ; un rayon repris garde une identité
  /// distincte.
  @Test func runsFollowTheRouteWithoutMovingItems() {
    let rows = [row("lait", "dairy"), row("yaourts", "dairy"), row("pâtes", "savory-grocery"), row("beurre", "dairy")]
    let sections = ShoppingSession.runs(of: rows, titles: ["dairy": "Crèmerie"])
    #expect(sections.map(\.id) == ["dairy", "savory-grocery", "dairy#1"])
    #expect(sections.map(\.title) == ["Crèmerie", "savory-grocery", "Crèmerie"])
    #expect(sections.flatMap(\.rows) == rows)
  }

  @Test func runsOfNothingAreEmpty() {
    #expect(ShoppingSession.runs(of: [], titles: [:]).isEmpty)
  }

  @Test func linesPutEachAisleBeforeItsItems() {
    let milk = row("lait", "dairy")
    let pasta = row("pâtes", "savory-grocery")
    let sections = ShoppingSession.runs(of: [milk, pasta], titles: [:])
    #expect(
      TicketLine.lines(of: sections).map(\.id) == [
        "aisle:dairy", milk.id.uuidString, "aisle:savory-grocery", pasta.id.uuidString,
      ])
  }

  @Test func raisedSectionsAreThoseThatOvertakeAnother() {
    #expect(TicketLine.raisedSections(previous: ["a", "b", "c"], current: ["a", "c", "b"]) == ["c"])
    #expect(TicketLine.raisedSections(previous: ["a", "b", "c"], current: ["c", "a", "b"]) == ["c"])
  }

  /// Un rayon vidé ou nouveau ne fait rien remonter : les autres ne font que se rapprocher du haut.
  @Test func removalOrAdditionRaisesNothing() {
    #expect(TicketLine.raisedSections(previous: ["a", "b", "c"], current: ["b", "c"]).isEmpty)
    #expect(TicketLine.raisedSections(previous: ["a", "b"], current: ["d", "a", "b"]).isEmpty)
    #expect(TicketLine.raisedSections(previous: ["a", "b"], current: ["a", "b"]).isEmpty)
  }
}

struct AisleStyleTests {
  /// Chaque rayon du dictionnaire a une famille de couleur (sauf `other`) et une icône dans le catalogue.
  @Test func everyCategoryHasAFamilyAndAnIcon() throws {
    let ids = try CategoryResources.categories().map(\.id)
    for id in ids {
      #expect(id == "other" || AisleStyle.families[id] != nil, "famille manquante : \(id)")
      #expect(AisleStyle.iconName(id) == "cat.\(id)")
      #expect(UIImage(named: AisleStyle.iconName(id)) != nil, "icône manquante : \(id)")
    }
  }

  @Test func unknownAisleFallsBackToOther() {
    #expect(AisleStyle.iconName("rayon-inconnu") == "cat.other")
  }
}

/// Contrastes des jetons (WCAG 2.2) : texte ≥ 4,5:1, traits porteurs de sens ≥ 3:1, en clair, en sombre, et en
/// Contraste augmenté (texte ≥ 7:1).
struct PaletteContrastTests {
  private static let appearances: [(UIUserInterfaceStyle, UIAccessibilityContrast)] = [
    (.light, .normal), (.dark, .normal), (.light, .high), (.dark, .high),
  ]

  @Test(arguments: 0..<4) func textTokensAreReadable(appearance: Int) {
    let traits = Self.traits(appearance)
    let high = Self.appearances[appearance].1 == .high
    let minimum = high ? 7.0 : 4.5
    let paper = Self.resolve(Palette.paper, traits)
    for (name, color) in [("ink", Palette.ink), ("inkMuted", Palette.inkMuted), ("accent", Palette.accent)] {
      let ratio = Self.contrast(Self.resolve(color, traits), paper)
      #expect(ratio >= minimum, "\(name) sur paper : \(ratio)")
    }
    let onAccent = Self.contrast(Self.resolve(Palette.onAccent, traits), Self.resolve(Palette.accent, traits))
    #expect(onAccent >= 4.5, "onAccent sur accent : \(onAccent)")
  }

  @Test(arguments: 0..<4) func aisleColorsAreVisible(appearance: Int) {
    let traits = Self.traits(appearance)
    let paper = Self.resolve(Palette.paper, traits)
    for family in AisleStyle.Family.allCases {
      let id = AisleStyle.families.first { $0.value == family }?.key ?? ""
      let ratio = Self.contrast(Self.resolve(AisleStyle.color(id), traits), paper)
      #expect(ratio >= 4.5, "\(family) sur paper : \(ratio)")
    }
  }

  /// Contraste augmenté : le fil à parcourir et les anneaux des perles tiennent 3:1.
  @Test func idleThreadIsVisibleWithIncreasedContrast() {
    for appearance in [2, 3] {
      let traits = Self.traits(appearance)
      let ratio = Self.contrast(Self.resolve(Palette.threadIdle, traits), Self.resolve(Palette.paper, traits))
      #expect(ratio >= 3, "threadIdle : \(ratio)")
    }
  }

  private static func traits(_ index: Int) -> UITraitCollection {
    let (style, contrast) = appearances[index]
    return UITraitCollection { traits in
      traits.userInterfaceStyle = style
      traits.accessibilityContrast = contrast
    }
  }

  private static func resolve(_ color: Color, _ traits: UITraitCollection) -> UIColor {
    UIColor(color).resolvedColor(with: traits)
  }

  private static func luminance(_ color: UIColor) -> Double {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: nil)
    func channel(_ value: CGFloat) -> Double {
      let v = Double(value)
      return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
  }

  private static func contrast(_ a: UIColor, _ b: UIColor) -> Double {
    let (l1, l2) = (luminance(a), luminance(b))
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
  }
}
