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
  /// le couloir finisse le mouvement sans marquer d'arrêt. Jamais de rebond, animations réduites ou non.
  static func release(velocity: CGFloat, from current: CGFloat, to target: CGFloat) -> Animation {
    let distance = target - current
    let initial = abs(distance) < 1 ? 0 : min(max(velocity / distance, -20), 20)
    // Sans rebond, comme le `.swipeActions` natif : un rebond faisait osciller la ligne au relâcher d'un glisser lent.
    return .interpolatingSpring(duration: 0.35, bounce: 0, initialVelocity: Double(initial))
  }
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
    content
      .background(Palette.paper)
      // Une seule source animée : le décalage. Le contenu et le bouton en dérivent à chaque image (`LaneSlide`).
      .modifier(
        LaneSlide(
          offset: currentOffset, action: action, actionWidth: actionWidth,
          fullSwipeWidth: action?.allowsFullSwipe == true && laneWidth > 0
            ? laneWidth * LaneMotion.fullSwipeShare : nil
        ) {
          if let action { perform(action) }
        }
      )
      .clipped()
      // Glisser posé sur la cellule par une vue d'ancrage, hors des gestes de SwiftUI (voir `LanePan`).
      // Rendus de test (`injectedOffset`) : pas de vue UIKit, qu'`ImageRenderer` ne dessine pas.
      .background {
        if injectedOffset == nil {
          LanePan(
            isEnabled: action != nil, state: panState, onChange: changed, onEnd: ended, onCancel: cancelled)
        }
      }
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
    let animation = LaneMotion.release(velocity: velocity, from: shown, to: target)
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

/// Décalage du couloir et bouton révélé, dérivés d'une seule valeur animable : pendant une animation, SwiftUI rappelle
/// `body` à chaque image avec le décalage interpolé, et la largeur, la hauteur et les opacités du bouton en découlent.
/// Le bouton n'existe que si une place est découverte : le `if` est évalué ici, à chaque image, sur le décalage
/// interpolé, et le bouton naît et disparaît à largeur nulle, sans transition. Avant, il était inséré par un `if` dans
/// `RowLane`, sur l'état final, et sa géométrie passée en valeur ; au relâcher, sa disparition animée repartait d'un
/// état périmé (capsule fantôme à la taille ouverte, sur iPhone). Un bouton toujours présent mais de largeur nulle ne
/// convenait pas non plus : `.accessibilityHidden` ne le retirait pas de l'arbre d'accessibilité, et XCUITest trouvait
/// un « Pas trouvé » par ligne fermée.
nonisolated private struct LaneSlide: ViewModifier, Animatable {
  var offset: CGFloat
  let action: LaneAction?
  let actionWidth: CGFloat
  /// Seuil du glisser complet, s'il est permis : au-delà, la capsule s'étire, pictogramme contre le contenu.
  let fullSwipeWidth: CGFloat?
  let perform: () -> Void

  var animatableData: CGFloat {
    get { offset }
    set { offset = newValue }
  }

  func body(content: Content) -> some View {
    let revealed = max(0, -offset)
    content
      .offset(x: offset)
      // Posé après le décalage, au bord du couloir, sur la seule place que le contenu a quittée : il ne recouvre rien.
      // Au-dessus du contenu, il passe avant l'élément de la ligne au test de toucher de l'accessibilité (sous lui,
      // XCUITest le jugeait « not hittable »).
      .overlay(alignment: .trailing) {
        if let action, revealed >= 1 {
          button(action, revealed: revealed)
            .transition(.identity)
        }
      }
  }

  /// Part du glisser complet atteinte, de 0 (ouverture) à 1 (au seuil) : étirement de la capsule.
  private func stretch(_ revealed: CGFloat) -> CGFloat {
    guard let fullSwipeWidth, fullSwipeWidth > actionWidth else { return 0 }
    let start = actionWidth + (fullSwipeWidth - actionWidth) * 0.6
    return min(max((revealed - start) / (fullSwipeWidth - start), 0), 1)
  }

  /// Bouton à la forme du `.swipeActions` natif de la version d'iOS : capsule sur iOS 26, rectangle plein hauteur
  /// sur iOS 18. Il occupe exactement la place découverte et se rétracte avec elle.
  @MainActor
  private func button(_ action: LaneAction, revealed: CGFloat) -> some View {
    Button(action: perform) {
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
  /// dessous, en texte secondaire (relevé sur `ListsView`). Elle naît d'une pastille et s'allonge au glisser complet,
  /// pictogramme contre le contenu, libellé effacé. Tout varie continûment avec la place découverte.
  @MainActor
  private func capsuleLabel(_ action: LaneAction, revealed: CGFloat) -> some View {
    let margin: CGFloat = 11
    let width = max(0, revealed - margin * 2)
    let height = min(34, width)
    let stretch = stretch(revealed)
    let iconOpacity = min(max((width - 18) / 12, 0), 1)
    let labelOpacity = min(max((width - 40) / 16, 0), 1) * (1 - stretch)
    // Pictogramme : au centre, puis glissé contre le contenu à mesure que la capsule s'étire.
    let iconInset = 14 + (max(14, width / 2 - 11) - 14) * (1 - stretch)
    return VStack(spacing: 4) {
      Capsule()
        .fill(action.tint)
        .frame(width: width, height: height)
        .overlay(alignment: .leading) {
          Image(systemName: action.systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(action.foreground)
            .frame(width: 22)
            .offset(x: iconInset)
            .opacity(iconOpacity)
        }
      Text(action.title)
        .font(.footnote)
        .foregroundStyle(Palette.inkMuted)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .fixedSize()
        .opacity(labelOpacity)
    }
  }

  /// iOS 18 : rectangle plein hauteur, pictogramme et libellé blancs. Le libellé reste centré tant que le bouton
  /// s'ouvre, puis glisse contre le contenu quand il s'étire.
  @MainActor
  private func rectangleLabel(_ action: LaneAction, revealed: CGFloat) -> some View {
    let lead = max(0, revealed - actionWidth) * stretch(revealed)
    return VStack(spacing: 2) {
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
    .offset(x: -lead / 2)
    .frame(width: revealed)
    .frame(maxHeight: .infinity)
    .background(action.tint)
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

/// Glisser du couloir, posé sur la cellule de la `List` et non dans les gestes de SwiftUI : comme le balayage natif de
/// « Mes listes », qui est un pan UIKit de la liste, rien n'attend son échec. Posé par `.gesture()`, il entrait dans
/// l'arbitrage de SwiftUI, et le `contextMenu` et l'appui long de la ligne attendaient qu'il échoue, ce qu'un doigt
/// posé ne fait qu'au relâcher : sur iPhone, le menu ne s'ouvrait qu'au relâcher (44830fa), plus tard (échec forcé à
/// 200 ms, 63912a2) ou plus du tout (0658856, où la reconnaissance simultanée ne levait pas cette attente).
///
/// La vue d'ancrage, au fond du couloir, ne reçoit aucun toucher : elle donne le cadre du couloir et pose le pan sur
/// la cellule qui la contient. Le pan ne garde que les touchers qui commencent dans ce cadre, ne démarre qu'après
/// `LaneSwipeRecognizer.slop` de mouvement horizontal dominant, hors des 24 pt du bord d'écran, et échoue sur un
/// mouvement vertical. Ligne fermée, il refuse un mouvement vers la fin de ligne et cède au geste retour (bord
/// d'écran, et plein écran sur iOS 26) ; ligne ouverte, c'est le geste retour qui l'attend : un glisser vers la fin
/// de ligne referme la ligne sans quitter l'écran.
private struct LanePan: UIViewRepresentable {
  let isEnabled: Bool
  let state: LanePanState
  let onChange: (CGFloat) -> Void
  /// Relâcher : vitesse logique.
  let onEnd: (CGFloat) -> Void
  let onCancel: () -> Void
  @Environment(\.layoutDirection) private var direction

  func makeUIView(context: Context) -> LaneAnchorView {
    let view = LaneAnchorView(recognizer: context.coordinator.recognizer)
    context.coordinator.anchor = view
    return view
  }

  func updateUIView(_ view: LaneAnchorView, context: Context) {
    let coordinator = context.coordinator
    coordinator.recognizer.isEnabled = isEnabled
    coordinator.state = state
    coordinator.sign = direction == .rightToLeft ? -1 : 1
    coordinator.onChange = onChange
    coordinator.onEnd = onEnd
    coordinator.onCancel = onCancel
  }

  static func dismantleUIView(_ view: LaneAnchorView, coordinator: Coordinator) {
    view.detach()
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    let recognizer = LaneSwipeRecognizer()
    weak var anchor: UIView?
    var state = LanePanState()
    /// -1 en écriture de droite à gauche : la fin de ligne est à gauche.
    var sign: CGFloat = 1
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }
    var onCancel: () -> Void = {}
    private var isOpen: Bool { state.isOpen }

    override init() {
      super.init()
      recognizer.addTarget(self, action: #selector(handle(_:)))
      recognizer.delegate = self
    }

    @objc private func handle(_ recognizer: LaneSwipeRecognizer) {
      // Décalage logique : négatif vers le début de ligne (côté gouttière), quel que soit le sens d'écriture.
      let translation = recognizer.translation.x * sign
      let velocity = recognizer.velocity.x * sign
      switch recognizer.state {
      case .began, .changed: onChange(translation)
      case .ended: onEnd(velocity)
      case .cancelled, .failed: onCancel()
      default: break
      }
    }

    /// Seuls les touchers qui commencent dans le couloir : la gouttière et le reste de la cellule n'en font pas partie.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard let anchor, anchor.window != nil else { return false }
      return anchor.bounds.contains(touch.location(in: anchor))
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
      guard let swipe = gesture as? LaneSwipeRecognizer, let window = gesture.view?.window else { return false }
      // Bord d'écran : le geste retour garde la priorité.
      let start = swipe.startLocation.x
      if start < 24 || start > window.bounds.width - 24 { return false }
      // Ligne fermée : rien à faire vers la fin de ligne, ce mouvement revient au geste retour plein écran.
      return isOpen || swipe.translation.x * sign < 0
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

    /// Interaction du menu contextuel (gestes d'UIKit qui ne sont pas des pans) : en même temps que le glisser. Les
    /// gestes de SwiftUI (toucher, bouton, appui long) et les pans (défilement, gestes retour) gardent leur exclusion :
    /// un glisser qui démarre les annule, sans coche ni menu au relâcher.
    func gestureRecognizer(
      _ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      guard !(other is UIPanGestureRecognizer) else { return false }
      return !NSStringFromClass(type(of: other)).contains("SwiftUI")
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

/// Vue d'ancrage du glisser : au fond du couloir, sans toucher ; elle pose le pan sur la cellule qui la contient, et
/// l'en retire quand elle quitte la fenêtre ou que la ligne disparaît.
final class LaneAnchorView: UIView {
  private let recognizer: UIGestureRecognizer
  private weak var host: UIView?

  init(recognizer: UIGestureRecognizer) {
    self.recognizer = recognizer
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas pris en charge") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    let target = window == nil ? nil : Self.cell(containing: self)
    guard target !== host else { return }
    host?.removeGestureRecognizer(recognizer)
    host = target
    target?.addGestureRecognizer(recognizer)
  }

  func detach() {
    host?.removeGestureRecognizer(recognizer)
    host = nil
  }

  /// Cellule de la liste qui contient la vue ; à défaut (rendu hors liste), aucun glisser.
  private static func cell(containing view: UIView) -> UIView? {
    var current = view.superview
    while let candidate = current, !(candidate is UIWindow) {
      if candidate is UICollectionViewCell || candidate is UITableViewCell { return candidate }
      current = candidate.superview
    }
    return nil
  }
}

/// Glisser horizontal à seuil, comme le balayage natif : il reste en attente tant que le doigt n'a pas parcouru
/// `slop` (un doigt posé pour l'appui long bouge de quelques points), démarre si le mouvement est surtout horizontal,
/// échoue s'il est surtout vertical (défilement). La translation part du point où il démarre : le couloir ne saute
/// pas du seuil. Positions dans le repère de la fenêtre, qui ne bouge pas avec le couloir.
final class LaneSwipeRecognizer: UIGestureRecognizer {
  /// Mouvement avant de décider (pt).
  static let slop: CGFloat = 10
  /// Durée sur laquelle la vitesse du relâcher est mesurée.
  private static let velocityWindow: TimeInterval = 0.08

  private(set) var startLocation: CGPoint = .zero
  private var origin: CGPoint = .zero
  private(set) var translation: CGPoint = .zero
  private(set) var velocity: CGPoint = .zero
  private var samples: [(point: CGPoint, time: TimeInterval)] = []

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    guard state == .possible, let touch = touches.first, event.allTouches?.count == 1 else {
      if state == .possible { state = .failed }
      return
    }
    let point = touch.location(in: nil)
    startLocation = point
    origin = point
    translation = .zero
    velocity = .zero
    samples = [(point, touch.timestamp)]
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    guard let touch = touches.first else { return }
    let point = touch.location(in: nil)
    record(point, at: touch.timestamp)
    switch state {
    case .possible:
      let dx = abs(point.x - startLocation.x)
      let dy = abs(point.y - startLocation.y)
      if dy >= Self.slop && dy >= dx {
        state = .failed
      } else if dx >= Self.slop && dx > dy {
        origin = point
        translation = .zero
        state = .began
      }
    case .began, .changed:
      translation = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
      state = .changed
    default:
      break
    }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    if let touch = touches.first { record(touch.location(in: nil), at: touch.timestamp) }
    state = state == .began || state == .changed ? .ended : .failed
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    state = state == .began || state == .changed ? .cancelled : .failed
  }

  override func reset() {
    super.reset()
    samples = []
    translation = .zero
    velocity = .zero
  }

  /// Vitesse sur les dernières `velocityWindow` secondes.
  private func record(_ point: CGPoint, at time: TimeInterval) {
    samples.append((point, time))
    let recent = samples.filter { time - $0.time <= Self.velocityWindow }
    samples = recent.count >= 2 ? recent : Array(samples.suffix(2))
    guard let first = samples.first, let last = samples.last, last.time > first.time else { return }
    let elapsed = CGFloat(last.time - first.time)
    velocity = CGPoint(x: (last.point.x - first.point.x) / elapsed, y: (last.point.y - first.point.y) / elapsed)
  }
}
