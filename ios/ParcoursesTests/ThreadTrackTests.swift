import CoreGraphics
import SwiftUI
import Testing

@testable import Parcourses

/// Tronçons du trait unique (#115) : mêmes cas que `ThreadTrackSegmentsTest` sur Android.
struct ThreadTrackSegmentsTests {
  private let height: CGFloat = 800

  @Test func theTrackRunsFromFirstToLastMarkerAndIsWalkedUpToTheNextBead() {
    #expect(
      threadTrackSegments(first: .visible(40), next: .visible(200), last: .visible(600), height: height)
        == ThreadTrackSegments(top: 40, junction: 200, bottom: 600))
  }

  /// Écran Liste : la perle suivante est le premier marqueur.
  @Test func nothingIsWalkedWhileTheListIsPrepared() {
    #expect(
      threadTrackSegments(first: .visible(40), next: .visible(40), last: .visible(600), height: height)
        == ThreadTrackSegments(top: 40, junction: 40, bottom: 600))
  }

  @Test func everythingIsWalkedWhenNoBeadIsLeft() {
    #expect(
      threadTrackSegments(first: .visible(40), next: .absent, last: .visible(600), height: height)
        == ThreadTrackSegments(top: 40, junction: 600, bottom: 600))
  }

  @Test func anEndOffScreenStopsAtTheEdge() {
    #expect(
      threadTrackSegments(first: .above, next: .visible(300), last: .below, height: height)
        == ThreadTrackSegments(top: 0, junction: 300, bottom: height))
  }

  /// Au-dessus : tout le visible est à parcourir ; au-dessous : tout est parcouru.
  @Test func aNextBeadOffScreenDecidesTheWholeVisibleTrack() {
    #expect(
      threadTrackSegments(first: .above, next: .above, last: .visible(600), height: height)
        == ThreadTrackSegments(top: 0, junction: 0, bottom: 600))
    #expect(
      threadTrackSegments(first: .visible(40), next: .below, last: .below, height: height)
        == ThreadTrackSegments(top: 40, junction: height, bottom: height))
  }

  @Test func aMarkerPartlyOffScreenIsClampedToTheList() {
    #expect(
      threadTrackSegments(first: .visible(-12), next: .visible(-12), last: .visible(height + 20), height: height)
        == ThreadTrackSegments(top: 0, junction: 0, bottom: height))
  }

  @Test func noTrackIsDrawnWhenNothingOfItIsVisible() {
    #expect(threadTrackSegments(first: .absent, next: .absent, last: .absent, height: height) == nil)
    // Un seul arrêt : pas de trait.
    #expect(threadTrackSegments(first: .visible(40), next: .visible(40), last: .visible(40), height: height) == nil)
    // Fil entièrement au-dessous ou au-dessus de l'écran.
    #expect(threadTrackSegments(first: .below, next: .below, last: .below, height: height) == nil)
    #expect(threadTrackSegments(first: .above, next: .absent, last: .above, height: height) == nil)
  }
}

/// Lecture des positions publiées par les gouttières : rôles par indice, bouts hors écran, repère du calque.
@MainActor
struct ThreadTrackModelTests {
  private func model(
    visible: [String: CGFloat], originY: CGFloat = 0, scale: CGFloat = 1, height: CGFloat = 800
  ) -> ThreadTrackModel {
    let model = ThreadTrackModel()
    model.markerY = visible
    model.visible = Set(visible.keys)
    model.track = TrackGeometry(originY: originY, scale: scale, height: height)
    return model
  }

  /// Positions publiées dans la fenêtre : l'origine du calque du trait est soustraite.
  @Test func markersAreReadInTheTrackLayer() {
    let model = model(visible: ["a": 100, "b": 160, "c": 220], originY: 62)
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b", "c"], next: 1))
        == ThreadTrackSegments(top: 38, junction: 98, bottom: 158))
  }

  /// Calque réduit par un parent (écran sous une feuille) : les positions de la fenêtre sont ramenées à son échelle.
  @Test func aScaledLayerIsCompensated() {
    let model = model(visible: ["a": 110, "b": 210], originY: 10, scale: 0.5, height: 800)
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b"], next: 2))
        == ThreadTrackSegments(top: 200, junction: 400, bottom: 400))
  }

  /// Règle commune avec Android : le trait couvre toute perle visible du fil, même au-delà d'un bout.
  @Test func theTrackCoversEveryVisibleBead() {
    let model = model(visible: ["a": 100, "b": 500, "c": 300])
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b", "c"], next: 0))
        == ThreadTrackSegments(top: 100, junction: 100, bottom: 500))
  }

  /// Lignes hors écran : le premier et la perle suivante au-dessus, le dernier au-dessous.
  @Test func offScreenEndsAreDecidedByIndex() {
    let model = model(visible: ["c": 300, "d": 400])
    // Une position périmée d'une ligne sortie de l'écran ne compte pas.
    model.markerY["a"] = 500
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b", "c", "d", "e"], next: 1))
        == ThreadTrackSegments(top: 0, junction: 0, bottom: 800))
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b", "c", "d", "e"], next: 4))
        == ThreadTrackSegments(top: 0, junction: 800, bottom: 800))
  }

  @Test func everythingIsWalkedPastTheLastBead() {
    let model = model(visible: ["a": 100, "b": 200])
    #expect(
      model.segments(for: ThreadPath(ids: ["a", "b"], next: 2))
        == ThreadTrackSegments(top: 100, junction: 200, bottom: 200))
  }

  /// Aucune ligne du fil à l'écran (ticket défilé jusqu'au panier) : pas de trait.
  @Test func noVisibleStopDrawsNoTrack() {
    let model = model(visible: [:])
    model.markerY = ["a": 100, "b": 200]
    #expect(model.segments(for: ThreadPath(ids: ["a", "b"], next: 0)) == nil)
  }
}

/// Gouttière invariante (#115, §6.4) : quoi que fasse le couloir (glisser partiel ou complet, appui), les pixels de
/// la gouttière, où passe le trait, sont identiques à ceux de la ligne au repos.
@MainActor
struct ThreadGutterTests {
  private static let width: CGFloat = 360
  private static let scale: CGFloat = 2

  /// Ligne du mode courses : perle suivante, case, libellé et quantité ; décalage du couloir injecté.
  private func row(offset: CGFloat?, pressed: Bool = false) -> some View {
    let action = LaneAction(
      title: "Pas trouvé", systemImage: "questionmark.circle", tint: Palette.notFoundSwipe, allowsFullSwipe: true
    ) {}
    return ThreadRow(id: "milk") {
      Bead(state: .next)
    } lane: {
      RowLane(id: "milk", openId: .constant(nil), action: action, injectedOffset: offset) {
        ItemLine(label: "Lait demi-écrémé", quantity: "2", isChecked: false, isNext: true, authorMark: "L")
      }
    }
    .environment(\.lanePressed, pressed)
    .frame(width: Self.width)
    .background(Palette.paper)
  }

  private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// Colonnes `0..<columns` de chaque rangée.
    func columns(_ columns: Int) -> [UInt8] {
      (0..<height).flatMap { y in bytes[(y * width * 4)..<(y * width * 4 + columns * 4)] }
    }

    func columns(from start: Int) -> [UInt8] {
      (0..<height).flatMap { y in bytes[(y * width * 4 + start * 4)..<((y + 1) * width * 4)] }
    }
  }

  private func render(_ view: some View) throws -> Bitmap {
    let renderer = ImageRenderer(content: view)
    renderer.scale = Self.scale
    let image = try #require(renderer.cgImage)
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return Bitmap(width: width, height: height, bytes: bytes)
  }

  /// Décalages : ligne ouverte, glisser complet en cours ; puis couloir enfoncé.
  @Test(arguments: [CGFloat(-88), -250])
  func gutterIsUnchangedWhenTheLaneSlides(offset: CGFloat) throws {
    let rest = try render(row(offset: nil))
    let slid = try render(row(offset: offset))
    #expect(rest.width == slid.width && rest.height == slid.height)
    // Gouttière et écart jusqu'au couloir : le couloir est rogné à son bord.
    let gutter = Int((TicketMetrics.threadGutter + Space.xs) * Self.scale)
    #expect(rest.columns(gutter) == slid.columns(gutter), "la gouttière a changé")
    // Garde-fou : le couloir, lui, a bien glissé.
    #expect(rest.columns(from: gutter) != slid.columns(from: gutter))
  }

  @Test func gutterIsUnchangedWhenTheLaneIsPressed() throws {
    let rest = try render(row(offset: nil))
    let pressed = try render(row(offset: nil, pressed: true))
    let gutter = Int((TicketMetrics.threadGutter + Space.xs) * Self.scale)
    #expect(rest.columns(gutter) == pressed.columns(gutter), "la gouttière a changé")
    #expect(rest.columns(from: gutter) != pressed.columns(from: gutter))
  }
}
