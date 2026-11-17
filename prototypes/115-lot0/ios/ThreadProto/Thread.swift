import Observation
import SwiftUI

// Les trois couches de l'option B (#115) : `ThreadTrack` (trait unique sous la liste), `ThreadGutter` (perle dans une
// colonne fixe), `RowLane` (couloir mobile). Prototype : couleurs franches pour la mesure à l'image près.

struct Item: Identifiable, Hashable {
  let id: Int
  var checked = false
}

enum Role {
  case first, next, last, other

  /// Couleurs de mesure : chaque rôle a la sienne, lue par `analyze.py` dans l'enregistrement.
  var color: Color {
    switch self {
    case .first: Color(red: 0, green: 0.8, blue: 0)
    case .next: Color(red: 1, green: 0, blue: 1)
    case .last: Color(red: 0, green: 0.8, blue: 1)
    case .other: .black
    }
  }
}

enum Metrics {
  static let gutter: CGFloat = 28
  static let bead: CGFloat = 14
  static let beadNext: CGFloat = 18
  static let threadWidth: CGFloat = 3
  /// Sonde de mesure : copie du trait décalée dans la gouttière, pour lire ses bouts même sous une perle.
  static let probeOffset: CGFloat = 11
  static let reorder = Animation.spring(response: 0.4, dampingFraction: 1)
  static let check = Animation.spring(response: 0.25, dampingFraction: 0.8)
}

extension VerticalAlignment {
  private enum ThreadMarker: AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat { context[VerticalAlignment.center] }
  }

  /// Hauteur de la perle dans la ligne : centre de la case. Valeur de mise en page, insensible aux effets de rendu.
  static let threadMarker = VerticalAlignment(ThreadMarker.self)
}

/// Positions publiées par les lignes, dans le repère de la liste (`.named(TrackModel.space)`).
@MainActor @Observable
final class TrackModel {
  static let space = "threadList"
  var markerY: [Int: CGFloat] = [:]
  var visible: Set<Int> = []
  /// Vrai pendant un tri, un départ, une coche : le trait anime ses bouts avec la même courbe que les lignes.
  var animated = false
  var listHeight: CGFloat = 0
  /// Origine du calque du trait dans le repère de la liste : le fond d'une `List` respecte l'encart de sécurité,
  /// pas le repère nommé posé sur elle (écart de 62 pt mesuré sur iPhone 17 Pro).
  var trackOriginY: CGFloat = 0
}

/// Rôles du fil pour un ordre donné : premier, prochain (premier non coché), dernier.
struct ThreadRoles {
  let first: Int?
  let next: Int?
  let last: Int?

  init(_ items: [Item]) {
    first = items.first?.id
    next = items.first { !$0.checked }?.id
    last = items.last?.id
  }

  func role(of id: Int) -> Role {
    if id == first { return .first }
    if id == last { return .last }
    if id == next { return .next }
    return .other
  }
}

/// `ThreadTrack` : hauteurs des bouts et de la jonction, en dehors de l'écran si la ligne n'est pas visible.
struct TrackEnds: Equatable {
  var top: CGFloat
  var junction: CGFloat
  var bottom: CGFloat

  @MainActor
  static func resolve(items: [Item], model: TrackModel) -> TrackEnds? {
    let roles = ThreadRoles(items)
    guard let first = roles.first, let last = roles.last else { return nil }
    let ids = items.map(\.id)
    let visibleIndices = ids.indices.filter { model.visible.contains(ids[$0]) && model.markerY[ids[$0]] != nil }
    guard let minVisible = visibleIndices.min(), let maxVisible = visibleIndices.max() else { return nil }
    let above: CGFloat = -40
    let below = model.listHeight + 40

    func y(_ id: Int, fallbackIndex index: Int) -> CGFloat {
      if model.visible.contains(id), let y = model.markerY[id] { return y }
      return index < minVisible ? above : below
    }

    let top = y(first, fallbackIndex: 0) - model.trackOriginY
    let bottom = y(last, fallbackIndex: ids.count - 1) - model.trackOriginY
    let junction: CGFloat
    if let next = roles.next, let index = ids.firstIndex(of: next) {
      junction = (index > maxVisible ? below : y(next, fallbackIndex: index)) - model.trackOriginY
    } else {
      junction = bottom
    }
    return TrackEnds(top: top, junction: junction, bottom: bottom)
  }
}

/// Un tronçon vertical du trait, entre deux hauteurs animables. `Shape` (non isolé) : SwiftUI interpole les hauteurs
/// image par image.
struct TrackSegment: Shape {
  var from: CGFloat
  var to: CGFloat
  var x: CGFloat
  var width: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(from, to) }
    set {
      from = newValue.first
      to = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    // Coordonnées de début de ligne : SwiftUI retourne la forme en RTL (vérifié sur capture par le prototype).
    Path(CGRect(x: x - width / 2, y: min(from, to), width: width, height: abs(to - from)))
  }
}

/// Trait unique : parcouru (accent) jusqu'à la perle suivante, puis à parcourir. Avec la sonde de mesure.
struct ThreadTrack: View {
  var ends: TrackEnds
  var probe: Bool

  var body: some View {
    let junction = min(max(ends.junction, ends.top), ends.bottom)
    let lines: [(CGFloat, CGFloat)] =
      [(Metrics.gutter / 2, Metrics.threadWidth)] + (probe ? [(Metrics.gutter / 2 + Metrics.probeOffset, 2)] : [])
    ZStack {
      ForEach(lines.indices, id: \.self) { index in
        let (x, width) = lines[index]
        TrackSegment(from: ends.top, to: junction, x: x, width: width).fill(Color(red: 1, green: 0, blue: 0))
        TrackSegment(from: junction, to: ends.bottom, x: x, width: width).fill(Color(red: 0, green: 0, blue: 1))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Perle dans la gouttière : cadre de hauteur nulle, aligné sur `.threadMarker`, qui déborde sans agrandir la ligne.
struct ThreadGutter: View {
  let id: Int
  let role: Role
  let checked: Bool
  let model: TrackModel

  var body: some View {
    let size = role == .next ? Metrics.beadNext : Metrics.bead
    Color.clear
      .frame(width: Metrics.gutter, height: 0)
      .overlay {
        Circle()
          .fill(checked ? role.color : Color(white: 0.98))
          .overlay { Circle().strokeBorder(role.color, lineWidth: 2) }
          .frame(width: size, height: size)
      }
      .alignmentGuide(.threadMarker) { $0[VerticalAlignment.center] }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.frame(in: .named(TrackModel.space)).midY
      } action: { y in
        model.markerY[id] = y
      }
      .onAppear { model.visible.insert(id) }
      .onDisappear { model.visible.remove(id) }
      .accessibilityHidden(true)
  }
}

/// Case : définit la hauteur du marqueur.
struct CheckBoxMark: View {
  let checked: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 4)
      .strokeBorder(Color.black.opacity(0.7), lineWidth: 2)
      .background(RoundedRectangle(cornerRadius: 4).fill(checked ? Color.black.opacity(0.7) : .clear))
      .frame(width: 28, height: 28)
      .alignmentGuide(.threadMarker) { $0[VerticalAlignment.center] }
  }
}

/// Couloir au repos : case, libellé, quantité.
struct LaneContent: View {
  let item: Item
  let role: Role

  var body: some View {
    HStack(alignment: .threadMarker, spacing: 12) {
      CheckBoxMark(checked: item.checked)
      Text("Article \(item.id)")
        .font(role == .next ? .title3 : .body)
        .strikethrough(item.checked)
      Spacer(minLength: 8)
      Text("×\(item.id % 3 + 1)").monospacedDigit()
    }
    .padding(.vertical, 14)
    .padding(.trailing, 16)
    .frame(minHeight: 56)
  }
}
