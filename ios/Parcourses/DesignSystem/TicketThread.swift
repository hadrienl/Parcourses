import SwiftUI

/// Place d'une ligne sur le fil du parcours (B3) : le fil passe dans la gouttière, de nœud de rayon en perle
/// d'article, et la partie parcourue est à la couleur d'accent.
struct ThreadPlace: Equatable {
  /// Pas de fil au-dessus (première ligne) ni au-dessous (dernière ligne).
  var isFirst = false
  var isLast = false
  /// Le fil parcouru arrive jusqu'à la perle ou au nœud de la ligne.
  var reachesMarker = false
  /// Le fil parcouru continue sous la ligne.
  var passesThrough = false

  /// Places des lignes d'un fil, dans l'ordre affiché. Le fil est parcouru jusqu'à la ligne `reached` (l'article
  /// suivant) ; `nil` : tout est parcouru ; `progress == false` : rien ne l'est (écran Liste).
  static func places(count: Int, reached: Int?, progress: Bool) -> [ThreadPlace] {
    (0..<count).map { index in
      let limit = progress ? (reached ?? count) : -1
      return ThreadPlace(
        isFirst: index == 0, isLast: index == count - 1, reachesMarker: index <= limit, passesThrough: index < limit)
    }
  }
}

/// Point d'accroche du fil dans une ligne : le centre de la case à cocher, ou du libellé d'un rayon.
private struct ThreadAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGPoint>? = nil
  static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
    value = value ?? nextValue()
  }
}

extension View {
  /// Marque l'élément dont le centre porte la perle ou le nœud du fil.
  func threadAnchor() -> some View {
    anchorPreference(key: ThreadAnchorKey.self, value: .center) { $0 }
  }
}

/// Ligne du ticket avec sa gouttière : le fil y est dessiné sur toute la hauteur de la ligne, et le marqueur
/// (perle ou nœud) au niveau de l'accroche du contenu. Purement décoratif pour VoiceOver.
struct ThreadRow<Marker: View, Content: View>: View {
  let place: ThreadPlace
  @ViewBuilder let marker: Marker
  @ViewBuilder let content: Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    HStack(alignment: .top, spacing: Space.xs) {
      Color.clear.frame(width: TicketMetrics.threadGutter, height: 1)
      content
    }
    // Toute la ligne est touchable, gouttière du fil comprise : `Color.clear` seul ne reçoit pas les touchers.
    .contentShape(Rectangle())
    .backgroundPreferenceValue(ThreadAnchorKey.self) { anchor in
      GeometryReader { proxy in
        let y = anchor.map { proxy[$0].y } ?? proxy.size.height / 2
        let x = TicketMetrics.threadGutter / 2
        ZStack(alignment: .topLeading) {
          if !place.isFirst {
            segment(reached: place.reachesMarker).frame(height: max(0, y)).offset(x: x - width / 2)
          }
          if !place.isLast {
            segment(reached: place.passesThrough)
              .frame(height: max(0, proxy.size.height - y))
              .offset(x: x - width / 2, y: y)
          }
          marker.position(x: x, y: y)
        }
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
      }
      .accessibilityHidden(true)
    }
  }

  private var width: CGFloat {
    contrast == .increased ? TicketMetrics.threadWidthIncreased : TicketMetrics.threadWidth
  }

  /// Tronçon de fil : le fil à parcourir, et par-dessus le fil parcouru, qui « coule » de haut en bas quand le
  /// parcours avance (fondu seul quand les animations sont réduites).
  private func segment(reached: Bool) -> some View {
    Rectangle()
      .fill(Palette.threadIdle)
      .overlay {
        Rectangle()
          .fill(Palette.thread)
          .scaleEffect(x: 1, y: reached || reduceMotion ? 1 : 0, anchor: .top)
          .opacity(reached || !reduceMotion ? 1 : 0)
      }
      .frame(width: width)
      .animation(Motion.check(reduced: reduceMotion), value: reached)
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
  let place: ThreadPlace
  @ViewBuilder var trailing: Trailing

  var body: some View {
    ThreadRow(place: place) {
      AisleNode(aisleId: aisleId)
    } content: {
      HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
        AisleTitle(title: title, accessibilityLabel: accessibilityLabel)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(identifier)
          .threadAnchor()
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
  init(aisleId: String, title: String, identifier: String, place: ThreadPlace) {
    self.init(aisleId: aisleId, title: title, identifier: identifier, place: place) { EmptyView() }
  }
}
