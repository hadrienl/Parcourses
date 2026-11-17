import SwiftUI
import UIKit

// Banc des gestes : un couloir (`RowLane`) placé dans le label d'un `Button`, avec un glisser maison, un style de
// bouton qui n'enfonce que le couloir et un `contextMenu` dont l'aperçu est le couloir seul. La gouttière et le trait
// ne doivent jamais bouger.

struct LaneLab: View {
  @State private var model = TrackModel()
  @State private var items = (0..<14).map { Item(id: $0, checked: $0 < 2) }
  @State private var openId: Int?
  @State private var status = "prêt"

  var body: some View {
    let roles = ThreadRoles(items)
    List {
      ForEach(items) { item in
        LaneRow(
          item: item,
          role: roles.role(of: item.id),
          model: model,
          openId: $openId,
          onTap: { status = "tap \(item.id)" },
          onDelete: { delete(item.id, how: "delete") },
          onNotFound: { status = "notFound \(item.id)" }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .coordinateSpace(.named(TrackModel.space))
    .animation(Metrics.reorder, value: items.map(\.id))
    .onScrollPhaseChange { _, phase in
      if phase != .idle, openId != nil { withAnimation(Metrics.reorder) { openId = nil } }
    }
    .background {
      if let ends = TrackEnds.resolve(items: items, model: model) {
        ThreadTrack(ends: ends, probe: false)
          .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TrackModel.space)).minY } action: {
            model.trackOriginY = $0
          }
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.listHeight = $0 }
    .background(Color(white: 0.98))
    .safeAreaInset(edge: .bottom) {
      Text(status)
        .font(.footnote.monospaced())
        .accessibilityIdentifier("status")
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.bar)
    }
    .navigationTitle("Couloir")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func delete(_ id: Int, how: String) {
    openId = nil
    items.removeAll { $0.id == id }
    status = "\(how) \(id)"
  }
}

struct LaneRow: View {
  let item: Item
  let role: Role
  let model: TrackModel
  @Binding var openId: Int?
  let onTap: () -> Void
  let onDelete: () -> Void
  let onNotFound: () -> Void

  @State private var drag: CGFloat = 0
  @State private var laneWidth: CGFloat = 300
  @Environment(\.layoutDirection) private var direction

  static let actionWidth: CGFloat = 96

  /// Décalage logique, négatif vers le début de ligne, côté gouttière (gauche en LTR, droite en RTL).
  private var offset: CGFloat {
    let rest = openId == item.id ? -Self.actionWidth : 0
    let raw = rest + drag
    // Rien vers la fin de ligne : on ne glisse que vers la gouttière.
    return raw > 0 ? 0 : raw
  }

  var body: some View {
    HStack(alignment: .threadMarker, spacing: 0) {
      ThreadGutter(id: item.id, role: role, checked: item.checked, model: model)
      lane
    }
  }

  private var lane: some View {
    ZStack(alignment: .trailing) {
      if offset < 0 {
        Button(role: .destructive, action: onDelete) {
          Text("Supprimer")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: max(Self.actionWidth, -offset))
            .frame(maxHeight: .infinity)
            .background(Color.red)
        }
        .buttonStyle(.borderless)
      }
      Button {
        if openId != nil {
          withAnimation(Metrics.reorder) { openId = nil }
        } else {
          onTap()
        }
      } label: {
        LaneContent(item: item, role: role)
          .background(Color(white: 0.98))
          .contentShape(Rectangle())
      }
      .buttonStyle(LaneButtonStyle())
      .accessibilityIdentifier("lane-\(item.id)")
      .accessibilityAction(named: "Supprimer", onDelete)
      // Essai : aperçu plus étroit que l'écran moins ses marges. Sans effet constaté (passage 4) : le système place
      // de toute façon la carte à 16 pt du bord d'écran, sur la gouttière de la ligne soulevée.
      .contentShape(.contextMenuPreview, TrailingInsetRectangle(inset: 20))
      .contextMenu {
        Button("Pas trouvé", action: onNotFound)
        Button("Supprimer", role: .destructive, action: onDelete)
      }
      .offset(x: offset)
      .gesture(
        LanePan(
          onChange: { drag = $0 },
          onEnd: { translation, velocity in settle(translation: translation, velocity: velocity) }
        )
      )
    }
    .clipped()
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { laneWidth = $0 }
  }

  /// Ouverture : distance projetée par la vitesse (`swipeLeft()` d'XCUITest est court et rapide). Glisser complet :
  /// distance réelle seulement, sinon un geste vif supprime au lieu d'ouvrir (constaté au premier passage).
  private func settle(translation: CGFloat, velocity: CGFloat) {
    let projected = offset + velocity * 0.15
    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
      drag = 0
      if -offset > laneWidth * 0.6 {
        onDelete()
      } else if -projected > Self.actionWidth / 2 {
        openId = item.id
      } else if openId == item.id {
        openId = nil
      }
    }
    _ = translation
  }
}

/// Rectangle rentré du côté de fin de ligne : forme de l'aperçu du menu contextuel.
struct TrailingInsetRectangle: Shape {
  let inset: CGFloat

  func path(in rect: CGRect) -> Path {
    Path(CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - inset), height: rect.height))
  }
}

/// N'enfonce que le couloir (0,97, depuis le bord de début) ; n'atténue rien.
struct LaneButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.97 : 1, anchor: .leading)
      .animation(Metrics.check, value: configuration.isPressed)
  }
}

/// Pan horizontal qui ne démarre que si le geste part d'abord à l'horizontale, hors du bord d'écran (geste retour).
struct LanePan: UIGestureRecognizerRepresentable {
  let onChange: (CGFloat) -> Void
  let onEnd: (CGFloat, CGFloat) -> Void
  @Environment(\.layoutDirection) private var direction

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.delegate = context.coordinator
    return pan
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    // Décalage logique : négatif vers le début de ligne (côté gouttière), quel que soit le sens d'écriture.
    let sign: CGFloat = direction == .rightToLeft ? -1 : 1
    let translation = recognizer.translation(in: recognizer.view).x * sign
    let velocity = recognizer.velocity(in: recognizer.view).x * sign
    switch recognizer.state {
    case .changed: onChange(translation)
    case .ended, .cancelled, .failed: onEnd(translation, velocity)
    default: break
    }
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return true }
      let velocity = pan.velocity(in: view)
      let location = pan.location(in: view.window)
      let width = view.window?.bounds.width ?? 0
      // Bord d'écran : le geste retour garde la priorité.
      if location.x < 24 || location.x > width - 24 { return false }
      return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
      other is UIScreenEdgePanGestureRecognizer
    }
  }
}
