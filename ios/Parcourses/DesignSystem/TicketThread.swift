import Observation
import SwiftUI

// Fil du ticket immobile (#115, option A′ : `docs/design/115-fil-immobile.md`, §4 B et §9.2). Trois couches :
// - `ThreadTrack` : le trait, dessiné une seule fois sous la liste, à abscisse fixe, du premier au dernier marqueur ;
// - `ThreadGutter` : colonne fixe de chaque ligne, qui porte la perle ou le nœud, jamais décalée ni enfoncée ;
// - `RowLane` (`RowLane.swift`) : couloir mobile, seule partie de la ligne qui glisse ou s'enfonce.
// Sur iOS, la liste change d'ordre sans animation : les bouts du trait, mesurés après la mise en page, ne suivraient
// pas les cellules animées par UIKit (lot 0, §9.2). Le trait reste ainsi exact à l'image près.

extension VerticalAlignment {
  private enum ThreadMarkerID: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
  }

  /// Hauteur du marqueur du fil dans une ligne : centre de la case (article) ou du titre (rayon). Valeur de mise en
  /// page : `offset`, `scaleEffect` et l'aperçu soulevé du menu, qui sont des effets de rendu, ne la changent pas.
  static let threadMarker = VerticalAlignment(ThreadMarkerID.self)
}

extension View {
  /// Marque l'élément dont le centre porte la perle ou le nœud du fil (`threadMarker`).
  func threadMarker() -> some View {
    alignmentGuide(.threadMarker) { $0[VerticalAlignment.center] }
  }
}

// MARK: - Tronçons du trait (fonction pure, mêmes cas sur Android)

/// Place d'un marqueur du fil (premier, suivant, dernier) par rapport à la partie visible de la liste.
nonisolated enum MarkerPlace: Equatable, Sendable {
  /// Visible : centre de la perle ou du nœud, en points dans le repère du calque du trait.
  case visible(CGFloat)
  /// Au-dessus du bord haut de la liste.
  case above
  /// Au-dessous du bord bas de la liste.
  case below
  /// Pas de marqueur : fil vide, ou pas de perle suivante quand tout est parcouru.
  case absent
}

/// Le trait visible : parcouru (accent) de `top` à `junction`, à parcourir de `junction` à `bottom`.
nonisolated struct ThreadTrackSegments: Equatable, Sendable {
  var top: CGFloat
  var junction: CGFloat
  var bottom: CGFloat
}

/// Tronçons du trait d'après ses trois marqueurs et la hauteur visible `height` : du premier au dernier marqueur,
/// ramené aux bords de la liste quand un bout est hors écran ; parcouru jusqu'à la perle suivante. Perle suivante
/// au-dessus de l'écran : tout le visible est à parcourir ; au-dessous, ou absente (tout est pris) : tout est parcouru.
/// `nil` quand aucun trait n'est visible (fil vide, d'un seul arrêt, ou entièrement hors écran). Même nom et mêmes cas
/// qu'Android (`threadTrackSegments`, `ThreadTrackSegmentsTest`).
nonisolated func threadTrackSegments(
  first: MarkerPlace, next: MarkerPlace, last: MarkerPlace, height: CGFloat
) -> ThreadTrackSegments? {
  let top: CGFloat? =
    switch first {
    case .visible(let y): min(max(y, 0), height)
    case .above: 0
    case .below, .absent: nil
    }
  let bottom: CGFloat? =
    switch last {
    case .visible(let y): min(max(y, 0), height)
    case .below: height
    case .above, .absent: nil
    }
  guard let top, let bottom, bottom > top else { return nil }
  let junction: CGFloat =
    switch next {
    case .visible(let y): y
    case .above: top
    case .below, .absent: bottom
    }
  return ThreadTrackSegments(top: top, junction: min(max(junction, top), bottom), bottom: bottom)
}

// MARK: - Trait unique de la liste

/// Le fil d'une liste : les identifiants de ses arrêts (rayons et articles) dans l'ordre affiché, et la position de la
/// perle suivante (`ids.count` quand tout est parcouru, 0 quand rien ne l'est, comme sur l'écran Liste).
struct ThreadPath: Equatable {
  let ids: [String]
  let next: Int
}

/// Calque du trait vu de la fenêtre : son coin haut gauche, son échelle (un parent peut le réduire) et sa hauteur
/// propre.
nonisolated struct TrackGeometry: Equatable, Sendable {
  var originX: CGFloat = 0
  var originY: CGFloat = 0
  var scale: CGFloat = 1
  var height: CGFloat = 0
}

/// Positions publiées par les gouttières (`ThreadGutter`), lues par le trait (`ThreadTrack`). Seul le trait lit ces
/// valeurs : les lignes ne font que les écrire, et ne sont donc pas redessinées quand elles changent.
///
/// Repère : la fenêtre (`.global`), pour les gouttières comme pour le calque. Un repère nommé posé sur la liste n'est
/// pas vu de la même façon depuis ses cellules et depuis son fond : le trait était décalé de la hauteur des barres.
@Observable
final class ThreadTrackModel {
  /// Centre du marqueur de chaque arrêt, dans la fenêtre. Une valeur peut être périmée hors écran : seules celles des
  /// lignes visibles comptent.
  var markerY: [String: CGFloat] = [:]
  /// Centre des gouttières, dans la fenêtre : toutes ont la même abscisse. `nil` avant la première mesure.
  var markerX: CGFloat?
  /// Gouttières affichées par arrêt (`onAppear` / `onDisappear`). Un compteur et non un ensemble : deux vues de même
  /// identifiant peuvent se relayer (ligne d'article qui passe en lecture seule), et l'apparition de la nouvelle peut
  /// précéder la disparition de l'ancienne. Un bout hors écran se décide par les indices.
  var visibleCount: [String: Int] = [:]
  /// Calque du trait, qui couvre aussi les barres (le fond d'une `List` respecterait l'encart de sécurité).
  var track = TrackGeometry()

  func gutterAppeared(_ id: String) {
    visibleCount[id, default: 0] += 1
  }

  /// Dernière gouttière de l'arrêt partie : sa position, désormais périmée, est oubliée.
  func gutterDisappeared(_ id: String) {
    let count = (visibleCount[id] ?? 0) - 1
    if count > 0 {
      visibleCount[id] = count
    } else {
      visibleCount[id] = nil
      markerY[id] = nil
    }
  }

  /// Une gouttière a bougé : centre dans la fenêtre.
  func gutterMoved(_ id: String, to center: CGPoint) {
    markerY[id] = center.y
    // Même valeur pour toutes les gouttières : on n'invalide le trait que si elle change.
    if markerX != center.x { markerX = center.x }
  }

  /// Abscisse du trait dans le calque : celle, mesurée, des gouttières.
  var trackX: CGFloat? {
    guard let markerX, track.scale > 0 else { return nil }
    return (markerX - track.originX) / track.scale
  }

  /// Tronçons à dessiner pour `path`, dans le repère du calque. Comme sur Android, le trait couvre toute perle
  /// visible du fil, au-delà du premier ou du dernier marqueur s'il le faut (sans effet en A′, où rien ne glisse).
  func segments(for path: ThreadPath) -> ThreadTrackSegments? {
    let ids = path.ids
    let height = track.height
    func local(_ id: String) -> CGFloat? {
      guard visibleCount[id] != nil, let y = markerY[id], track.scale > 0 else { return nil }
      return (y - track.originY) / track.scale
    }
    let firstVisible = ids.firstIndex { local($0) != nil }
    func place(_ index: Int) -> MarkerPlace {
      guard ids.indices.contains(index), let firstVisible else { return .absent }
      if let y = local(ids[index]) { return .visible(y) }
      return index < firstVisible ? .above : .below
    }
    let next = place(path.next)
    let base = threadTrackSegments(first: place(0), next: next, last: place(ids.count - 1), height: height)
    let beads = ids.compactMap(local).map { min(max($0, 0), height) }
    guard let top = ([base?.top] + beads).compactMap(\.self).min(),
      let bottom = ([base?.bottom] + beads).compactMap(\.self).max(), bottom > top
    else { return nil }
    let junction: CGFloat =
      base?.junction
      ?? {
        switch next {
        case .visible(let y): y
        case .above: top
        case .below, .absent: bottom
        }
      }()
    return ThreadTrackSegments(top: top, junction: min(max(junction, top), bottom), bottom: bottom)
  }
}

/// Le trait : une ligne verticale à abscisse fixe, parcourue (accent) jusqu'à la perle suivante, puis à parcourir.
/// Décoratif pour VoiceOver.
private struct ThreadTrack: View {
  let model: ThreadTrackModel
  let path: ThreadPath
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let width = contrast == .increased ? TicketMetrics.threadWidthIncreased : TicketMetrics.threadWidth
    // Abscisse mesurée sur les gouttières, dans la fenêtre : le calque est donc dessiné de gauche à droite, quel que
    // soit le sens d'écriture (sinon SwiftUI retournerait la forme une seconde fois).
    ZStack {
      if let x = model.trackX, let segments = model.segments(for: path) {
        TrackSegment(from: segments.top, to: segments.junction, x: x, width: width).fill(Palette.thread)
        TrackSegment(from: segments.junction, to: segments.bottom, x: x, width: width).fill(Palette.threadIdle)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onGeometryChange(for: TrackGeometry.self) { proxy in
      let frame = proxy.frame(in: .global)
      let height = proxy.size.height
      let scale: CGFloat = height > 0 ? frame.height / height : 1
      return TrackGeometry(originX: frame.minX, originY: frame.minY, scale: scale, height: height)
    } action: { geometry in
      model.track = geometry
    }
    .environment(\.layoutDirection, .leftToRight)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Un tronçon vertical du trait, entre deux hauteurs.
nonisolated private struct TrackSegment: Shape {
  var from: CGFloat
  var to: CGFloat
  var x: CGFloat
  var width: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(CGRect(x: x - width / 2, y: min(from, to), width: width, height: abs(to - from)))
  }
}

extension View {
  /// Pose le trait unique sous une liste du ticket. À placer avant le fond de papier (`ticketBackground()`) : le trait
  /// passe entre le papier et les lignes, dont la gouttière est transparente (`threadLineRow()`).
  func threadTrack(_ model: ThreadTrackModel, path: ThreadPath) -> some View {
    // Le calque couvre aussi les barres (`ignoresSafeArea`) : le fil passe dessous, comme les lignes qui défilent.
    background { ThreadTrack(model: model, path: path).ignoresSafeArea(edges: .vertical) }
      .environment(model)
  }
}

// MARK: - Ligne : gouttière fixe et couloir

/// Gouttière d'une ligne : la perle ou le nœud, posé dans un cadre de hauteur nulle aligné sur `.threadMarker`, qui
/// déborde sans agrandir la ligne (le nœud de rayon, 28 pt, dépasse du bas de `AisleLine`). Publie la position du
/// marqueur pour le trait. Ne glisse, ne s'enfonce et ne se soulève jamais. Décorative pour VoiceOver.
struct ThreadGutter<Marker: View>: View {
  let id: String
  @ViewBuilder let marker: Marker
  /// Absent hors d'une liste à fil (rendus de test, aperçus) : rien n'est publié.
  @Environment(ThreadTrackModel.self) private var track: ThreadTrackModel?

  var body: some View {
    Color.clear
      .frame(width: TicketMetrics.threadGutter, height: 0)
      .overlay { marker }
      .alignmentGuide(.threadMarker) { $0[VerticalAlignment.center] }
      .onGeometryChange(for: CGPoint.self) { proxy in
        let frame = proxy.frame(in: .global)
        return CGPoint(x: frame.midX, y: frame.midY)
      } action: { center in
        track?.gutterMoved(id, to: center)
      }
      .onAppear { track?.gutterAppeared(id) }
      .onDisappear { track?.gutterDisappeared(id) }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

/// Ligne du ticket : gouttière fixe (`ThreadGutter`) et couloir (`lane`), alignés sur le marqueur. Le couloir porte
/// le guide `.threadMarker` (case d'un article, titre d'un rayon).
struct ThreadRow<Marker: View, Lane: View>: View {
  /// Identifiant de l'arrêt dans le fil (`ThreadPath.ids`).
  let id: String
  /// Toucher la gouttière : même effet que toucher le couloir (mode courses, où le couloir est un bouton).
  var onGutterTap: (() -> Void)?
  @ViewBuilder let marker: Marker
  @ViewBuilder let lane: Lane

  var body: some View {
    HStack(alignment: .threadMarker, spacing: Space.xs) {
      ThreadGutter(id: id) { marker }
      lane
    }
    .background(alignment: .leading) {
      if let onGutterTap {
        Color.clear
          .frame(width: TicketMetrics.threadGutter + Space.xs)
          .contentShape(Rectangle())
          .onTapGesture(perform: onGutterTap)
          .accessibilityHidden(true)
      }
    }
  }
}

/// Titre d'un rayon : capitales espacées en couleur secondaire, la couleur du rayon restant sur le nœud.
/// VoiceOver lit le libellé tel quel (pas les capitales, épelées sinon).
struct AisleTitle: View {
  let title: String
  /// Lecture VoiceOver, si elle diffère du titre (nombre d'articles).
  var accessibilityLabel: String?

  var body: some View {
    Text(title)
      .font(TicketFont.aisle)
      .tracking(TicketFont.aisleTracking)
      .textCase(.uppercase)
      .foregroundStyle(Palette.inkMuted)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityLabel(Text(accessibilityLabel ?? title))
  }
}

/// Filet pointillé du ticket (sous l'en-tête, points de conduite entre l'article et sa quantité).
struct DottedRule: View {
  var dash: [CGFloat] = [1, 3]
  var lineWidth: CGFloat = 1

  var body: some View {
    GeometryReader { proxy in
      Path { path in
        // Sans largeur, rien : un trait nul à bouts ronds dessinerait un point.
        guard proxy.size.width > 0 else { return }
        path.move(to: CGPoint(x: 0, y: lineWidth / 2))
        path.addLine(to: CGPoint(x: proxy.size.width, y: lineWidth / 2))
      }
      .stroke(Palette.inkMuted, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash))
    }
    .frame(height: lineWidth)
    .accessibilityHidden(true)
  }
}

/// Ligne de rayon du ticket : nœud sur le fil, titre lu comme un en-tête, et un complément à droite (étiquette
/// « ↑ appris » du mode courses).
struct AisleLine<Trailing: View>: View {
  let aisleId: String
  let title: String
  /// Lecture VoiceOver : le titre, éventuellement suivi du nombre d'articles.
  var accessibilityLabel: String?
  /// Repère des tests UI, posé sur le titre.
  let identifier: String
  /// Identifiant de l'arrêt dans le fil.
  let threadId: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    ThreadRow(id: threadId) {
      AisleNode(aisleId: aisleId)
    } lane: {
      HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
        AisleTitle(title: title, accessibilityLabel: accessibilityLabel)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(identifier)
          .threadMarker()
        Spacer(minLength: 0)
        trailing
      }
      .padding(.top, Space.m)
      .padding(.bottom, Space.xs / 2)
      .frame(minHeight: TicketMetrics.aisleNode + Space.m, alignment: .bottom)
    }
  }
}

extension AisleLine where Trailing == EmptyView {
  init(aisleId: String, title: String, identifier: String, threadId: String) {
    self.init(aisleId: aisleId, title: title, identifier: identifier, threadId: threadId) { EmptyView() }
  }
}
