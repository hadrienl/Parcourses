import SwiftUI
import UIKit

// Couloir d'une ligne du ticket (#115, `docs/design/115-fil-immobile.md` §6.2) : seule partie de la ligne qui glisse
// ou s'enfonce. Le glisser maison remplace `.swipeActions`, qui décalait toute la cellule, fil compris, et dont le
// glisser complet recouvrait la gouttière. Le couloir est rogné à son bord : en glissant vers la gouttière, la case
// passe sous ce bord, et l'action n'occupe que le couloir.

/// Réglages du glisser du couloir.
enum LaneMotion {
  /// Glisser complet : décidé sur la distance réelle seulement. Avec la vitesse, un geste vif comme le `swipeLeft()`
  /// d'XCUITest supprimerait au lieu d'ouvrir (lot 0).
  static let fullSwipeShare: CGFloat = 0.6

  /// Ouverture et fermeture du couloir : léger rebond, aucun quand les animations sont réduites.
  static func settle(reduced: Bool) -> Animation {
    reduced ? .easeOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 0.86)
  }
}

/// Action révélée par le glisser du couloir.
struct LaneAction {
  let title: String
  let systemImage: String
  /// Fond du bouton, sous un libellé blanc (4,5:1 au moins).
  let tint: Color
  /// Glisser complet : l'action part au relâcher, au-delà de `LaneMotion.fullSwipeShare` du couloir.
  let allowsFullSwipe: Bool
  let perform: () -> Void
}

/// Couloir mobile d'une ligne. Le bouton d'action n'existe que ligne ouverte (ou pendant le glisser) et reste hors de
/// l'élément d'accessibilité du contenu : `app.buttons["Supprimer"]` le trouve, une seule fois. Le glisser n'est
/// jamais la seule voie : la ligne propose la même action à VoiceOver.
struct RowLane<Content: View>: View {
  /// Identifiant de la ligne, comparé à `openId`.
  let id: String
  /// Ligne ouverte de la liste : une seule à la fois.
  @Binding var openId: String?
  /// `nil` : pas de glisser (article coché du mode courses).
  let action: LaneAction?
  /// Décalage imposé, pour les rendus de test : la ligne est dessinée comme pendant un glisser.
  var injectedOffset: CGFloat?
  @ViewBuilder let content: Content

  @State private var drag: CGFloat = 0
  @State private var laneWidth: CGFloat = 0
  @State private var pastFullSwipe = false
  /// Largeur du bouton ouvert : grandit avec le texte, sans dépasser la moitié du couloir.
  @ScaledMetric(relativeTo: .subheadline) private var scaledActionWidth: CGFloat = 88
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let offset = currentOffset
    content
      .background(Palette.paper)
      .offset(x: offset)
      // Posé après le décalage, au bord du couloir, sur la seule place que le contenu a quittée : il ne recouvre rien.
      // Au-dessus du contenu, il passe avant l'élément de la ligne au test de toucher de l'accessibilité (sous lui,
      // XCUITest le jugeait « not hittable »).
      .overlay(alignment: .trailing) {
        if let action, offset < 0 {
          actionButton(action, revealed: -offset)
        }
      }
      .clipped()
      .gesture(
        LanePan(
          isEnabled: action != nil && injectedOffset == nil, isOpen: openId == id, onChange: changed, onEnd: ended,
          onCancel: cancelled)
      )
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        laneWidth = $0
      }
      .sensoryFeedback(.impact(weight: .medium), trigger: pastFullSwipe) { _, past in past }
  }

  private var actionWidth: CGFloat {
    laneWidth > 0 ? min(scaledActionWidth, laneWidth / 2) : scaledActionWidth
  }

  /// Décalage logique, négatif vers la gouttière (début de ligne), avant le rebond élastique.
  private var rawOffset: CGFloat {
    (openId == id ? -actionWidth : 0) + drag
  }

  private var currentOffset: CGFloat {
    if let injectedOffset { return injectedOffset }
    guard let action else { return 0 }
    // Rien vers la fin de ligne : on ne glisse que vers la gouttière.
    let distance = max(0, -rawOffset)
    if action.allowsFullSwipe || distance <= actionWidth {
      return -min(distance, laneWidth > 0 ? laneWidth : distance)
    }
    // Glisser partiel : au-delà du bouton, le couloir résiste.
    return -(actionWidth + (distance - actionWidth) * 0.3)
  }

  private func actionButton(_ action: LaneAction, revealed: CGFloat) -> some View {
    Button {
      perform(action)
    } label: {
      VStack(spacing: 2) {
        Image(systemName: action.systemImage).font(.body.weight(.semibold))
        Text(action.title)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
          .minimumScaleFactor(0.6)
      }
      .multilineTextAlignment(.center)
      .foregroundStyle(.white)
      .padding(.horizontal, Space.xs / 2)
      // Le libellé reste contre le contenu ; le fond remplit tout l'espace découvert (glisser complet).
      .frame(width: actionWidth)
      .frame(width: revealed, alignment: .leading)
      .frame(maxHeight: .infinity)
      .background(action.tint)
      .clipped()
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(action.title)
  }

  private var settle: Animation {
    LaneMotion.settle(reduced: reduceMotion)
  }

  private func changed(_ translation: CGFloat) {
    // Une seule ligne ouverte : glisser une autre ligne referme la première.
    if let open = openId, open != id { withAnimation(settle) { openId = nil } }
    drag = translation
    guard let action else { return }
    pastFullSwipe = action.allowsFullSwipe && laneWidth > 0 && -rawOffset > laneWidth * LaneMotion.fullSwipeShare
  }

  /// Ouverture : distance projetée par la vitesse (`swipeLeft()` d'XCUITest est court et rapide). Glisser complet :
  /// distance réelle.
  private func ended(_ velocity: CGFloat) {
    // Distance relevée avant de remettre le glisser à zéro, quoi qu'il arrive ensuite.
    let offset = rawOffset
    pastFullSwipe = false
    guard let action else {
      drag = 0
      return
    }
    if action.allowsFullSwipe, laneWidth > 0, -offset > laneWidth * LaneMotion.fullSwipeShare {
      perform(action)
      return
    }
    let projected = -(offset + velocity * 0.15)
    withAnimation(settle) {
      drag = 0
      if projected > actionWidth / 2 {
        openId = id
      } else if openId == id {
        openId = nil
      }
    }
  }

  /// Geste interrompu (appel, défilement qui reprend la main) : le couloir revient à sa place, sans action.
  private func cancelled() {
    pastFullSwipe = false
    withAnimation(settle) { drag = 0 }
  }

  /// L'action change la liste sans animation (option A′) : la ligne part d'un coup, le trait reste exact.
  private func perform(_ action: LaneAction) {
    drag = 0
    if openId == id { openId = nil }
    action.perform()
  }
}

extension View {
  /// Toucher cette zone hors des lignes (en-tête du ticket, dock) referme la ligne ouverte, sans prendre le toucher aux
  /// contrôles qu'elle contient.
  func closesOpenLane(_ close: @escaping () -> Void) -> some View {
    simultaneousGesture(TapGesture().onEnded(close))
  }
}

extension EnvironmentValues {
  /// Couloir enfoncé par `LanePressStyle` : `ItemLine` enfonce sa case et son texte.
  @Entry var lanePressed = false
}

/// Style du couloir du mode courses : n'atténue rien, et transmet l'appui à `ItemLine`, qui enfonce la case et le texte
/// (0,97, depuis le bord de début). La gouttière et le fil, hors du bouton, ne bougent pas.
struct LanePressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.environment(\.lanePressed, configuration.isPressed)
  }
}

/// Pan horizontal du couloir : il ne démarre que si le geste part d'abord à l'horizontale, hors des 24 pt du bord
/// d'écran. Il ne gêne ni le défilement de la liste, ni le toucher, ni l'appui long. Ligne fermée, il refuse un
/// mouvement vers la fin de ligne et cède au geste retour (bord d'écran, et plein écran sur iOS 26) ; ligne ouverte,
/// c'est le geste retour qui l'attend : un glisser vers la fin de ligne referme la ligne sans quitter l'écran.
private struct LanePan: UIGestureRecognizerRepresentable {
  let isEnabled: Bool
  /// La ligne de ce couloir est ouverte.
  let isOpen: Bool
  let onChange: (CGFloat) -> Void
  /// Relâcher : vitesse logique.
  let onEnd: (CGFloat) -> Void
  let onCancel: () -> Void
  @Environment(\.layoutDirection) private var direction

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.delegate = context.coordinator
    configure(pan, context.coordinator)
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    configure(recognizer, context.coordinator)
  }

  private func configure(_ recognizer: UIPanGestureRecognizer, _ coordinator: Coordinator) {
    recognizer.isEnabled = isEnabled
    coordinator.isOpen = isOpen
    coordinator.sign = direction == .rightToLeft ? -1 : 1
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    // Décalage logique : négatif vers le début de ligne (côté gouttière), quel que soit le sens d'écriture.
    let sign: CGFloat = direction == .rightToLeft ? -1 : 1
    let translation = recognizer.translation(in: recognizer.view).x * sign
    let velocity = recognizer.velocity(in: recognizer.view).x * sign
    switch recognizer.state {
    case .changed: onChange(translation)
    case .ended: onEnd(velocity)
    case .cancelled, .failed: onCancel()
    default: break
    }
  }

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var isOpen = false
    /// -1 en écriture de droite à gauche : la fin de ligne est à gauche.
    var sign: CGFloat = 1

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let pan = gesture as? UIPanGestureRecognizer, let view = pan.view else { return true }
      let velocity = pan.velocity(in: view)
      let location = pan.location(in: view.window)
      let width = view.window?.bounds.width ?? 0
      // Bord d'écran : le geste retour garde la priorité.
      if location.x < 24 || location.x > width - 24 { return false }
      // Ligne fermée : rien à faire vers la fin de ligne, ce mouvement revient au geste retour plein écran.
      if !isOpen && velocity.x * sign > 0 { return false }
      return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
      if other is UIScreenEdgePanGestureRecognizer { return true }
      return !isOpen && other === Self.contentPopGesture(near: gesture.view)
    }

    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
      isOpen && other === Self.contentPopGesture(near: gesture.view)
    }

    /// Geste retour plein écran de la pile de navigation (iOS 26), s'il y en a une.
    private static func contentPopGesture(near view: UIView?) -> UIGestureRecognizer? {
      guard #available(iOS 26, *) else { return nil }
      var responder: UIResponder? = view
      while let current = responder {
        if let navigation = (current as? UIViewController)?.navigationController {
          return navigation.interactiveContentPopGestureRecognizer
        }
        responder = current.next
      }
      return nil
    }
  }
}
