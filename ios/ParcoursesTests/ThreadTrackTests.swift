import CoreGraphics
import SwiftUI
import Testing

@testable import Parcourses

// Expressions découpées et typées : le compilateur de la CI (Xcode 26.6) ne vérifiait pas à temps les littéraux
// `CGFloat` mêlés aux énumérations dans `#expect`.

/// Tronçons du trait unique (#115) : mêmes cas que `ThreadTrackSegmentsTest` sur Android.
struct ThreadTrackSegmentsTests {
  private let height: CGFloat = 800

  private func segments(_ first: MarkerPlace, _ next: MarkerPlace, _ last: MarkerPlace) -> ThreadTrackSegments? {
    threadTrackSegments(first: first, next: next, last: last, height: height)
  }

  private func expected(_ top: CGFloat, _ junction: CGFloat, _ bottom: CGFloat) -> ThreadTrackSegments? {
    ThreadTrackSegments(top: top, junction: junction, bottom: bottom)
  }

  @Test func theTrackRunsFromFirstToLastMarkerAndIsWalkedUpToTheNextBead() {
    let actual: ThreadTrackSegments? = segments(.visible(40), .visible(200), .visible(600))
    #expect(actual == expected(40, 200, 600))
  }

  /// Écran Liste : la perle suivante est le premier marqueur.
  @Test func nothingIsWalkedWhileTheListIsPrepared() {
    let actual: ThreadTrackSegments? = segments(.visible(40), .visible(40), .visible(600))
    #expect(actual == expected(40, 40, 600))
  }

  @Test func everythingIsWalkedWhenNoBeadIsLeft() {
    let actual: ThreadTrackSegments? = segments(.visible(40), .absent, .visible(600))
    #expect(actual == expected(40, 600, 600))
  }

  @Test func anEndOffScreenStopsAtTheEdge() {
    let actual: ThreadTrackSegments? = segments(.above, .visible(300), .below)
    #expect(actual == expected(0, 300, height))
  }

  /// Au-dessus : tout le visible est à parcourir ; au-dessous : tout est parcouru.
  @Test func aNextBeadOffScreenDecidesTheWholeVisibleTrack() {
    let ahead: ThreadTrackSegments? = segments(.above, .above, .visible(600))
    #expect(ahead == expected(0, 0, 600))
    let walked: ThreadTrackSegments? = segments(.visible(40), .below, .below)
    #expect(walked == expected(40, height, height))
  }

  @Test func aMarkerPartlyOffScreenIsClampedToTheList() {
    let above: CGFloat = -12
    let below: CGFloat = height + 20
    let actual: ThreadTrackSegments? = segments(.visible(above), .visible(above), .visible(below))
    #expect(actual == expected(0, 0, height))
  }

  @Test func noTrackIsDrawnWhenNothingOfItIsVisible() {
    let empty: ThreadTrackSegments? = segments(.absent, .absent, .absent)
    #expect(empty == nil)
    // Un seul arrêt : pas de trait.
    let single: ThreadTrackSegments? = segments(.visible(40), .visible(40), .visible(40))
    #expect(single == nil)
    // Fil entièrement au-dessous ou au-dessus de l'écran.
    let below: ThreadTrackSegments? = segments(.below, .below, .below)
    #expect(below == nil)
    let above: ThreadTrackSegments? = segments(.above, .absent, .above)
    #expect(above == nil)
  }
}

/// Lecture des positions publiées par les gouttières : rôles par indice, bouts hors écran, repère du calque.
@MainActor
struct ThreadTrackModelTests {
  private func model(
    visible: [String: CGFloat], originY: CGFloat = 0, scale: CGFloat = 1, height: CGFloat = 800
  ) -> ThreadTrackModel {
    let model = ThreadTrackModel()
    let geometry = TrackGeometry(originX: 0, originY: originY, scale: scale, height: height)
    model.track = geometry
    for (id, y) in visible {
      model.gutterAppeared(id)
      model.gutterMoved(id, to: CGPoint(x: 30, y: y))
    }
    return model
  }

  private func expected(_ top: CGFloat, _ junction: CGFloat, _ bottom: CGFloat) -> ThreadTrackSegments? {
    ThreadTrackSegments(top: top, junction: junction, bottom: bottom)
  }

  /// Positions publiées dans la fenêtre : l'origine du calque du trait est soustraite.
  @Test func markersAreReadInTheTrackLayer() {
    let model = model(visible: ["a": 100, "b": 160, "c": 220], originY: 62)
    let path = ThreadPath(ids: ["a", "b", "c"], next: 1)
    let actual: ThreadTrackSegments? = model.segments(for: path)
    #expect(actual == expected(38, 98, 158))
  }

  /// Calque réduit par un parent (écran sous une feuille) : les positions de la fenêtre sont ramenées à son échelle.
  @Test func aScaledLayerIsCompensated() {
    let model = model(visible: ["a": 110, "b": 210], originY: 10, scale: 0.5)
    let path = ThreadPath(ids: ["a", "b"], next: 2)
    let actual: ThreadTrackSegments? = model.segments(for: path)
    #expect(actual == expected(200, 400, 400))
  }

  /// Règle commune avec Android : le trait couvre toute perle visible du fil, même au-delà d'un bout.
  @Test func theTrackCoversEveryVisibleBead() {
    let model = model(visible: ["a": 100, "b": 500, "c": 300])
    let path = ThreadPath(ids: ["a", "b", "c"], next: 0)
    let actual: ThreadTrackSegments? = model.segments(for: path)
    #expect(actual == expected(100, 100, 500))
  }

  /// Lignes hors écran : le premier et la perle suivante au-dessus, le dernier au-dessous.
  @Test func offScreenEndsAreDecidedByIndex() {
    let model = model(visible: ["c": 300, "d": 400])
    let ids: [String] = ["a", "b", "c", "d", "e"]
    let ahead: ThreadTrackSegments? = model.segments(for: ThreadPath(ids: ids, next: 1))
    #expect(ahead == expected(0, 0, 800))
    let walked: ThreadTrackSegments? = model.segments(for: ThreadPath(ids: ids, next: 4))
    #expect(walked == expected(0, 800, 800))
  }

  @Test func everythingIsWalkedPastTheLastBead() {
    let model = model(visible: ["a": 100, "b": 200])
    let actual: ThreadTrackSegments? = model.segments(for: ThreadPath(ids: ["a", "b"], next: 2))
    #expect(actual == expected(100, 200, 200))
  }

  /// Aucune ligne du fil à l'écran (ticket défilé jusqu'au panier) : pas de trait.
  @Test func noVisibleStopDrawsNoTrack() {
    let model = model(visible: ["a": 100, "b": 200])
    model.gutterDisappeared("a")
    model.gutterDisappeared("b")
    let actual: ThreadTrackSegments? = model.segments(for: ThreadPath(ids: ["a", "b"], next: 0))
    #expect(actual == nil)
  }

  /// Deux vues de même identifiant se relaient (ligne passée en lecture seule) : la nouvelle apparaît avant que
  /// l'ancienne ne disparaisse, et l'arrêt reste visible. La dernière partie, sa position est oubliée, et l'arrêt
  /// compte comme hors écran (au-dessous, d'après son indice).
  @Test func visibilityIsCountedPerGutter() {
    let model = model(visible: ["a": 100, "b": 200])
    model.gutterAppeared("b")
    model.gutterDisappeared("b")
    let path = ThreadPath(ids: ["a", "b"], next: 0)
    let kept: ThreadTrackSegments? = model.segments(for: path)
    #expect(kept == expected(100, 100, 200))
    model.gutterDisappeared("b")
    let markerY: CGFloat? = model.markerY["b"]
    #expect(markerY == nil)
    let gone: ThreadTrackSegments? = model.segments(for: path)
    #expect(gone == expected(100, 100, 800))
  }

  /// Abscisse du trait : celle mesurée sur les gouttières, ramenée au calque (origine et échelle).
  @Test func theTrackIsDrawnAtTheMeasuredGutter() {
    let model = ThreadTrackModel()
    let unmeasured: CGFloat? = model.trackX
    #expect(unmeasured == nil)
    model.track = TrackGeometry(originX: 20, originY: 0, scale: 0.5, height: 800)
    model.gutterAppeared("a")
    model.gutterMoved("a", to: CGPoint(x: 50, y: 100))
    let measured: CGFloat? = model.trackX
    #expect(measured == 60)
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

    /// Octets des colonnes `range` de chaque rangée.
    func columns(_ range: Range<Int>) -> [UInt8] {
      var result: [UInt8] = []
      let rowBytes: Int = width * 4
      for y in 0..<height {
        let start: Int = y * rowBytes + range.lowerBound * 4
        let end: Int = y * rowBytes + range.upperBound * 4
        result.append(contentsOf: bytes[start..<end])
      }
      return result
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

  /// Gouttière et écart jusqu'au couloir, en pixels : le couloir est rogné à son bord.
  private var gutterColumns: Int {
    let points: CGFloat = TicketMetrics.threadGutter + Space.xs
    return Int(points * Self.scale)
  }

  /// Décalages : ligne ouverte, glisser complet en cours.
  @Test(arguments: [CGFloat(-88), CGFloat(-250)])
  func gutterIsUnchangedWhenTheLaneSlides(offset: CGFloat) throws {
    let rest = try render(row(offset: nil))
    let slid = try render(row(offset: offset))
    #expect(rest.width == slid.width)
    #expect(rest.height == slid.height)
    let gutter: Range<Int> = 0..<gutterColumns
    let lane: Range<Int> = gutterColumns..<rest.width
    #expect(rest.columns(gutter) == slid.columns(gutter), "la gouttière a changé")
    // Garde-fou : le couloir, lui, a bien glissé.
    #expect(rest.columns(lane) != slid.columns(lane))
  }

  @Test func gutterIsUnchangedWhenTheLaneIsPressed() throws {
    let rest = try render(row(offset: nil))
    let pressed = try render(row(offset: nil, pressed: true))
    let gutter: Range<Int> = 0..<gutterColumns
    let lane: Range<Int> = gutterColumns..<rest.width
    #expect(rest.columns(gutter) == pressed.columns(gutter), "la gouttière a changé")
    #expect(rest.columns(lane) != pressed.columns(lane))
  }
}
