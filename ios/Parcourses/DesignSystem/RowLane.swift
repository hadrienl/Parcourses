import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

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

  /// Relâcher : le ressort part à la vitesse du doigt, exprimée en part de la distance restante par seconde, pour que
  /// le couloir finisse le mouvement sans marquer d'arrêt. Sans rebond quand les animations sont réduites.
  static func release(velocity: CGFloat, from current: CGFloat, to target: CGFloat, reduced: Bool) -> Animation {
    let distance = target - current
    let initial = abs(distance) < 1 ? 0 : min(max(velocity / distance, -20), 20)
    return .interpolatingSpring(duration: 0.35, bounce: reduced ? 0 : 0.1, initialVelocity: Double(initial))
  }

  /// Pan immobile depuis ce délai : il échoue, et laisse la main au toucher, à l'appui long et au menu.
  static let stillPanTimeout: Duration = .milliseconds(200)
}

/// Action révélée par le glisser du couloir.
struct LaneAction {
  let title: String
  let systemImage: String
  /// Fond du bouton (capsule sur iOS 26, rectangle sur iOS 18).
  let tint: Color
  /// Pictogramme, et libellé sur iOS 18, posés sur `tint` : 4,5:1 au moins.
  var foreground: Color = .white
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
  /// État lu en direct par le délégué du pan : une copie faite à la mise à jour de la vue pouvait être en retard, et
  /// le geste retour emportait alors l'écran au lieu de refermer la ligne.
  @State private var panState = LanePanState()
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
          isEnabled: action != nil && injectedOffset == nil, state: panState, onChange: changed, onEnd: ended,
          onCancel: cancelled)
      )
      .onChange(of: openId == id, initial: true) { _, open in panState.isOpen = open }
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

  /// Bouton révélé, à la forme du `.swipeActions` natif de la version d'iOS : capsule sur iOS 26, rectangle plein
  /// hauteur sur iOS 18. Il occupe exactement la place découverte et se rétracte avec elle.
  private func actionButton(_ action: LaneAction, revealed: CGFloat) -> some View {
    Button {
      perform(action)
    } label: {
      Group {
        if #available(iOS 26, *) {
          capsuleLabel(action, revealed: revealed)
        } else {
          rectangleLabel(action, revealed: revealed)
        }
      }
      .frame(width: revealed)
      .frame(maxHeight: .infinity)
      .clipped()
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(action.title)
  }

  /// iOS 26 : capsule de 34 pt de haut, à 11 pt des bords de la place découverte, pictogramme seul dedans et libellé
  /// dessous, en texte secondaire (relevé sur `ListsView`). Elle naît d'une pastille, s'allonge au glisser complet,
  /// pictogramme contre le contenu, sans libellé.
  private func capsuleLabel(_ action: LaneAction, revealed: CGFloat) -> some View {
    let margin: CGFloat = 11
    let width = max(0, revealed - margin * 2)
    let height = min(34, width)
    return VStack(spacing: 4) {
      Capsule()
        .fill(action.tint)
        .frame(width: width, height: height)
        .overlay(alignment: pastFullSwipe ? .leading : .center) {
          Image(systemName: action.systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(action.foreground)
            .padding(.horizontal, 14)
            .opacity(width >= 28 ? 1 : 0)
        }
      Text(action.title)
        .font(.footnote)
        .foregroundStyle(Palette.inkMuted)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .fixedSize()
        .opacity(width >= 48 && !pastFullSwipe ? 1 : 0)
    }
  }

  /// iOS 18 : rectangle plein hauteur, pictogramme et libellé blancs. Le libellé reste centré tant que le bouton
  /// s'ouvre, puis contre le contenu quand il s'étire.
  private func rectangleLabel(_ action: LaneAction, revealed: CGFloat) -> some View {
    VStack(spacing: 2) {
      Image(systemName: action.systemImage).font(.body.weight(.semibold))
      Text(action.title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .minimumScaleFactor(0.6)
    }
    .multilineTextAlignment(.center)
    .foregroundStyle(action.foreground)
    .padding(.horizontal, Space.xs / 2)
    .frame(width: actionWidth)
    .frame(width: revealed, alignment: revealed > actionWidth ? .leading : .center)
    .frame(maxHeight: .infinity)
    .background(action.tint)
  }

  private var settle: Animation {
    LaneMotion.settle(reduced: reduceMotion)
  }

  private func changed(_ translation: CGFloat) {
    // Une seule ligne ouverte : glisser une autre ligne referme la première.
    if let open = openId, open != id { withAnimation(settle) { openId = nil } }
    // Le couloir suit le doigt, sans animation : rien ne doit s'interposer entre le doigt et la ligne.
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { drag = translation }
    guard let action else { return }
    pastFullSwipe = action.allowsFullSwipe && laneWidth > 0 && -rawOffset > laneWidth * LaneMotion.fullSwipeShare
  }

  /// Ouverture : distance projetée par la vitesse (`swipeLeft()` d'XCUITest est court et rapide), et sens du geste :
  /// un relâcher vif vers la fin de ligne ferme, vers la gouttière ouvre. Glisser complet : distance réelle. Le ressort
  /// part de la position affichée, à la vitesse du doigt.
  private func ended(_ velocity: CGFloat) {
    // Distance relevée avant de remettre le glisser à zéro, quoi qu'il arrive ensuite.
    let offset = rawOffset
    let shown = currentOffset
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
    let opens = abs(velocity) > 300 ? velocity < 0 : projected > actionWidth / 2
    let target: CGFloat = opens ? -actionWidth : 0
    let animation = LaneMotion.release(velocity: velocity, from: shown, to: target, reduced: reduceMotion)
    withAnimation(animation) {
      drag = 0
      if opens {
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

/// État du couloir partagé avec le délégué du pan, lu au moment où UIKit le consulte.
final class LanePanState {
  /// La ligne de ce couloir est ouverte.
  var isOpen = false
}

/// Pan qui échoue s'il n'a pas démarré après `LaneMotion.stillPanTimeout` : un doigt posé sans glisser ne le garde pas
/// en attente jusqu'au relâcher. Sans cela, ce qui attend son échec (appui long, menu contextuel, toucher) ne se
/// décidait qu'au relâcher : le menu s'ouvrait alors, et l'article était coché du même coup.
final class LanePanRecognizer: UIPanGestureRecognizer {
  private var touchGeneration = 0

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesBegan(touches, with: event)
    touchGeneration += 1
    let generation = touchGeneration
    Task { [weak self] in
      try? await Task.sleep(for: LaneMotion.stillPanTimeout)
      guard let self, self.touchGeneration == generation, self.state == .possible else { return }
      self.state = .failed
    }
  }

  override func reset() {
    super.reset()
    touchGeneration += 1
  }
}

/// Pan horizontal du couloir : il ne démarre que si le geste part d'abord à l'horizontale, hors des 24 pt du bord
/// d'écran. Il ne gêne ni le défilement de la liste, ni le toucher, ni l'appui long. Ligne fermée, il refuse un
/// mouvement vers la fin de ligne et cède au geste retour (bord d'écran, et plein écran sur iOS 26) ; ligne ouverte,
/// c'est le geste retour qui l'attend : un glisser vers la fin de ligne referme la ligne sans quitter l'écran.
private struct LanePan: UIGestureRecognizerRepresentable {
  let isEnabled: Bool
  let state: LanePanState
  let onChange: (CGFloat) -> Void
  /// Relâcher : vitesse logique.
  let onEnd: (CGFloat) -> Void
  let onCancel: () -> Void
  @Environment(\.layoutDirection) private var direction

  func makeUIGestureRecognizer(context: Context) -> LanePanRecognizer {
    let pan = LanePanRecognizer()
    pan.delegate = context.coordinator
    configure(pan, context.coordinator)
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: LanePanRecognizer, context: Context) {
    configure(recognizer, context.coordinator)
  }

  private func configure(_ recognizer: LanePanRecognizer, _ coordinator: Coordinator) {
    recognizer.isEnabled = isEnabled
    coordinator.state = state
    coordinator.sign = direction == .rightToLeft ? -1 : 1
  }

  func handleUIGestureRecognizerAction(_ recognizer: LanePanRecognizer, context: Context) {
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
    var state = LanePanState()
    private var isOpen: Bool { state.isOpen }
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
      // Le geste retour plein écran d'abord : s'il est aussi un geste de bord, la règle du bord le ferait toujours
      // passer devant, même ligne ouverte.
      if other === Self.contentPopGesture(near: gesture.view) { return !isOpen }
      return other is UIScreenEdgePanGestureRecognizer
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
