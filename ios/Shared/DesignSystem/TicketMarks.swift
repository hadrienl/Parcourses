import SwiftUI

// Marques du fil, partagées par l'app et la Live Activity (#52).

/// État d'une perle d'article.
enum BeadState: Equatable {
  /// Article coché : perle pleine.
  case done
  /// Prochain article du trajet : anneau plus grand, à la couleur d'accent.
  case next
  case idle
}

/// Perle d'un article sur le fil.
struct Bead: View {
  let state: BeadState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let size = state == .next ? TicketMetrics.beadNext : TicketMetrics.bead
    Circle()
      .fill(state == .done ? Palette.thread : Palette.paper)
      .overlay {
        Circle().strokeBorder(state == .idle ? Palette.threadIdle : Palette.thread, lineWidth: TicketMetrics.beadRing)
      }
      .frame(width: size, height: size)
      .animation(Motion.check(reduced: reduceMotion), value: state)
  }
}

/// Nœud d'un rayon sur le fil : icône au trait dans un anneau, à la couleur du rayon.
struct AisleNode: View {
  let aisleId: String
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    let color = AisleStyle.color(aisleId)
    Circle()
      .fill(Palette.paper)
      .overlay {
        Circle().strokeBorder(color, lineWidth: contrast == .increased ? 2 : TicketMetrics.aisleNodeRing)
      }
      .overlay {
        Image(AisleStyle.iconName(aisleId))
          .resizable()
          .renderingMode(.template)
          .scaledToFit()
          .frame(width: TicketMetrics.aisleIcon, height: TicketMetrics.aisleIcon)
          .foregroundStyle(color)
      }
      .frame(width: TicketMetrics.aisleNode, height: TicketMetrics.aisleNode)
  }
}

/// Compteur du ticket sur deux chiffres : « 05 ».
enum TicketCounter {
  static func text(_ value: Int) -> String {
    value < 10 ? "0\(max(0, value))" : "\(value)"
  }
}
