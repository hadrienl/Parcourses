import SwiftUI
import UIKit

/// Indication du champ de saisie : plus foncée que le gris clair du système, qui ne tient pas 4,5:1.
enum EntryPrompt {
  /// Invite qui montre qu'une quantité se tape avec l'article (#110).
  static let placeholder = "Ajouter un article (ex.\u{00A0}: 2 lait)"

  static var text: Text {
    Text(placeholder).foregroundStyle(Palette.inkMuted)
  }

  /// Invite courte du dock du mode courses : l'exemple ne tient pas à côté de « Terminer », le dock passerait sur deux
  /// rangées (Android affiche aussi « Ajouter un article » au repos dans ce dock).
  static let shortPlaceholder = "Ajouter un article"

  static var shortText: Text {
    Text(shortPlaceholder).foregroundStyle(Palette.inkMuted)
  }
}

/// Champ de saisie : la case visible fait au moins 44 pt, et toute la case donne le focus, marges comprises.
/// Fond de papier opaque : posé sur le verre du dock, le texte saisi garde son contraste quoi qu'il passe dessous.
private struct EntryFieldStyle: ViewModifier {
  let focus: FocusState<Bool>.Binding
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    content
      .textFieldStyle(.plain)
      .foregroundStyle(Palette.ink)
      .focused(focus)
      // Marge de 12 pt : un appui au début de la case place le curseur avant le texte (testEntryFieldKeepsEditingGestures).
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(Palette.paper, in: shape)
      .overlay { shape.strokeBorder(Palette.paperEdge, lineWidth: contrast == .increased ? 1.5 : 1) }
      .contentShape(shape)
      .onTapGesture { focus.wrappedValue = true }
  }
}

/// Hauteur d'un bouton plein (jeton `size.primaryAction`, maquette `.bar` / `.cta`).
enum ProminentButtonSize {
  /// Bouton seul : 56 pt.
  case standalone
  /// Dans le dock flottant, à côté du champ : 44 pt, pour un dock de 56 pt comme la barre de la maquette.
  case dock

  var minHeight: CGFloat {
    switch self {
    case .standalone: TicketMetrics.primaryAction
    case .dock: TicketMetrics.touchMin
    }
  }
}

/// Bouton plein : accent et texte `onAccent` (8:1 en clair, 7,6:1 en sombre), en capsule.
private struct ProminentButtonStyle: ButtonStyle {
  var size = ProminentButtonSize.standalone
  /// Bouton à pictogramme seul : marges réduites.
  var compact = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: size.minHeight / 2, style: .continuous)
    configuration.label
      .font(.body.weight(.bold))
      // Désactivé : texte secondaire sur le bord du papier ; l'encre en Contraste augmenté, où le fond fonce.
      .foregroundStyle(isEnabled ? Palette.onAccent : (contrast == .increased ? Palette.ink : Palette.inkMuted))
      .padding(.horizontal, compact ? Space.xs / 2 : Space.l)
      .padding(.vertical, Space.xs / 2)
      .frame(minHeight: size.minHeight)
      .background(isEnabled ? Palette.accent : Palette.paperEdge, in: shape)
      .opacity(configuration.isPressed ? 0.8 : 1)
      .contentShape(shape)
  }
}

extension View {
  /// Champ de saisie rapide du dock, lié à son état de focus.
  func entryField(focus: FocusState<Bool>.Binding) -> some View {
    modifier(EntryFieldStyle(focus: focus))
  }

  /// Cible tactile d'au moins 44 pt, à poser **dans le label** d'un bouton : c'est la zone touchable.
  /// Minimum constant (#9 §11) : le texte fait grandir la cible de lui-même avec Dynamic Type, un minimum mis à
  /// l'échelle n'ajouterait que du vide (×3 en AX5).
  func touchTarget(minHeight: Double = 44) -> some View {
    frame(minHeight: minHeight).contentShape(Rectangle())
  }

  /// Ligne : 48 pt au moins, même règle.
  func rowHeight() -> some View {
    touchTarget(minHeight: 48)
  }

  /// Bouton principal : plein, à l'accent du ticket, 56 pt au moins seul, 44 pt dans le dock (sa propre zone
  /// tactile).
  func prominentButton(size: ProminentButtonSize = .standalone, compact: Bool = false) -> some View {
    buttonStyle(ProminentButtonStyle(size: size, compact: compact))
  }

  /// Liste qui défile sous le dock : pas d'effet de bord de défilement (iOS 26), dont le flou rend illisible le
  /// texte qui passe dessous (l'audit de contraste le rejette, aux grandes tailles de texte). Le dock a son verre.
  @ViewBuilder func opaqueBottomBar() -> some View {
    if #available(iOS 26, *) {
      scrollEdgeEffectHidden(true, for: .bottom)
    } else {
      self
    }
  }

  /// Écran sans barre de navigation (le ticket porte son titre) : sur iOS 18, le contenu défilerait sous la barre
  /// d'état, sans fond, l'heure par-dessus le texte. Une bande de papier la couvre. iOS 26 y pose son effet de bord
  /// de défilement.
  @ViewBuilder func statusBarPaper() -> some View {
    if #available(iOS 26, *) {
      self
    } else {
      safeAreaInset(edge: .top, spacing: 0) {
        Color.clear
          .frame(height: 0)
          .background(Palette.paper.ignoresSafeArea(edges: .top))
          .accessibilityHidden(true)
      }
    }
  }

  /// Dock flottant du bas : marges du bord de l'écran et verre de Parcourses.
  func floatingDock() -> some View {
    padding(Space.xs / 2 + 2)
      .parcoursesGlass()
      .padding(.horizontal, Space.m)
      .padding(.bottom, Space.xs)
  }

  /// Bannière flottante (« Annuler ») : papier opaque, filet et ombre légère. Le verre est réservé à la barre basse
  /// (jeton `material.ios26`) ; sur le verre clair d'iOS 26, l'audit de contraste rejette le libellé à l'accent alors
  /// que la capture mesure 7,7:1.
  func ticketBanner() -> some View {
    let shape = RoundedRectangle(cornerRadius: TicketMetrics.primaryAction / 2, style: .continuous)
    // Ombre sur le fond seul : posée sur la vue entière, elle ombrerait aussi le texte (halo rejeté par l'audit).
    return background {
      shape.fill(Palette.paper).shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
    .overlay { shape.strokeBorder(Palette.paperEdge, lineWidth: 1) }
  }

  /// Ligne d'une liste habillée en ticket : pas de séparateur, fond de papier.
  func ticketRow() -> some View {
    ticketRow(background: Palette.paper)
  }

  /// Ligne sur le fil (`ThreadRow`) : fond transparent, pour laisser voir le trait unique dessiné sous la liste
  /// (`threadTrack`) dans la gouttière. Le couloir (`RowLane`) porte son propre papier.
  func threadLineRow() -> some View {
    ticketRow(background: .clear)
  }

  private func ticketRow(background: Color) -> some View {
    listRowInsets(EdgeInsets(top: 0, leading: Space.m, bottom: 0, trailing: Space.m))
      .listRowSeparator(.hidden)
      .listRowBackground(background)
  }

  /// Fond d'écran du ticket, sous une liste ou une vue qui défile.
  func ticketBackground() -> some View {
    scrollContentBackground(.hidden).background(Palette.paper)
  }
}

/// État vide, à la manière de `ContentUnavailableView` : pictogramme décoratif à la teinte de l'app, titre et
/// description en éléments distincts, jamais tronqués. `ContentUnavailableView` regroupe pictogramme et titre dans
/// un seul nœud que l'audit de contraste rejette.
struct EmptyState: View {
  let title: String
  let systemImage: String
  let description: String

  var body: some View {
    // Centré quand il tient, ouvert en haut quand il déborde (AX5, clavier ouvert) : un cadre de hauteur fixe le
    // centrerait en débordant sous la barre de navigation.
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 8) {
          Image(systemName: systemImage)
            .font(.largeTitle)
            .imageScale(.large)
            .foregroundStyle(.tint)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
          Text(title)
            .font(TicketFont.title)
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
          Text(description)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(Palette.inkMuted)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding()
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}

/// Ligne d'article du ticket, partagée par l'écran Liste et le mode courses : case carrée, libellé en chasse fixe,
/// points de conduite et quantité. L'état coché se lit sans la couleur : case pleine avec coche (forme) et texte
/// barré. Un libellé trop long se replie seul, la quantité restant alignée à droite sur sa dernière ligne, reliée par
/// les points de conduite ; quand elle prendrait trop de place (quantité très longue, très grand texte), elle passe
/// sous le libellé. La case porte le guide du marqueur du fil (`threadMarker()`).
struct ItemLine: View {
  let label: String
  let quantity: String?
  let isChecked: Bool
  /// Prochain article du trajet : libellé plus grand et plus gras.
  var isNext = false
  /// Initiale de l'auteur sur une liste partagée (#87), à droite de la première ligne. Décorative.
  var authorMark: String?
  /// Lecture seule (lecteur) : pas de case ; un article coché porte une coche ✓, un article à prendre rien.
  var readOnly = false
  /// Appui long en cours (#110) : seuls la case et le texte s'enfoncent, depuis leur bord gauche ; la marque d'auteur,
  /// comme le fil, reste immobile (même règle qu'Android).
  var pressed = false
  /// Appui transmis par le style du couloir (`LanePressStyle`, mode courses) : même enfoncement.
  @Environment(\.lanePressed) private var lanePressed
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Largeur de la dernière ligne du libellé (`Text.LayoutKey`) : les points de conduite d'un libellé replié partent
  /// de la fin de son texte (#110).
  @State private var lastLineWidth: CGFloat?
  @ScaledMetric(relativeTo: .body) private var box = TicketMetrics.checkBox
  /// Demi-hauteur des capitales du libellé : la case s'aligne sur le milieu de la première ligne.
  @ScaledMetric(relativeTo: .body) private var capHalf: CGFloat = 6
  @ScaledMetric(relativeTo: .title3) private var capHalfNext: CGFloat = 7

  var body: some View {
    // Une seule mise en page, qui garde les mêmes vues quand le texte grandit. `ViewThatFits` remplaçait libellé et
    // quantité par d'autres vues : l'audit Dynamic Type mesurait alors des nœuds qui ne grandissaient pas
    // (« partially unsupported » sur la ligne à quantité).
    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
      HStack(alignment: .firstTextBaseline, spacing: Space.s) {
        checkBox
        LeaderLineLayout(spacing: Space.s, leaderMinWidth: Space.m, lastLineWidth: lastLineWidth) {
          title
          DottedRule()
          quantityText
        }
      }
      .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1, anchor: .leading)
      .opacity(isPressed ? 0.85 : 1)
      // Enfoncement retardé de 0,1 s, comme le surlignage d'une cellule UIKit : un glisser qui démarre ne fait pas
      // d'abord s'enfoncer puis ressortir la ligne (#115). Le relâcher, lui, est immédiat.
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.15).delay(isPressed ? 0.1 : 0), value: isPressed)
      if let authorMark { AuthorMark(initial: authorMark) }
    }
    .padding(.vertical, Space.xs)
    .frame(minHeight: TicketMetrics.rowMin)
    .contentShape(Rectangle())
  }

  private var isPressed: Bool {
    pressed || lanePressed
  }

  @ViewBuilder private var checkBox: some View {
    let offset = isNext ? capHalfNext : capHalf
    if readOnly {
      Image(systemName: "checkmark")
        .font(.body.weight(.bold))
        .foregroundStyle(Palette.inkMuted)
        .opacity(isChecked ? 1 : 0)
        .frame(width: min(box, 44), height: min(box, 44))
        .accessibilityHidden(true)
        .threadMarker()
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + offset }
    } else {
      CheckBox(isChecked: isChecked, size: min(box, 44))
        .threadMarker()
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + offset }
    }
  }

  private var title: some View {
    Text(label)
      .font(isNext ? TicketFont.itemNext : TicketFont.item)
      .strikethrough(isChecked)
      .foregroundStyle(isChecked ? Palette.checked : Palette.ink)
      .fixedSize(horizontal: false, vertical: true)
      // Le libellé passe avant les points de conduite, qui ne prennent que la place restante.
      .layoutPriority(1)
      .onPreferenceChange(Text.LayoutKey.self) { layouts in
        lastLineWidth = layouts.first?.layout.last?.typographicBounds.rect.maxX
      }
  }

  @ViewBuilder private var quantityText: some View {
    if let quantity {
      Text(quantity).font(TicketFont.quantity).foregroundStyle(Palette.inkMuted)
    }
  }
}

/// Libellé, points de conduite et quantité sur une ligne quand le libellé y tient en entier. Sinon (#110), seul le
/// libellé se replie ; la quantité reste une colonne à droite qui ne se coupe jamais, alignée sur la ligne de base de
/// la dernière ligne du libellé, et les points de conduite relient la fin du texte à la quantité (la largeur proposée
/// au libellé leur réserve un minimum : un mot qui ne laisserait pas cette place passe à la ligne). Si cette colonne
/// dépasse `maxQuantityShare` de la largeur, la quantité passe sous le libellé. Sous-vues : libellé, points de
/// conduite, puis quantité (facultative). La ligne de base est celle du libellé.
struct LeaderLineLayout: Layout {
  var spacing: CGFloat
  var leaderMinWidth: CGFloat
  /// Écart entre le libellé et la quantité placée dessous.
  var stackSpacing: CGFloat = 2
  /// Part de la largeur que la quantité peut prendre à droite d'un libellé replié (#110). Au-delà (quantité très
  /// longue, très grand texte), le libellé n'aurait plus que quelques caractères par ligne : la quantité passe dessous.
  var maxQuantityShare: CGFloat = 0.4
  /// Largeur de la dernière ligne du libellé replié, relevée sur le texte affiché ; `nil` avant le premier relevé
  /// (pas de points de conduite le temps d'une passe).
  var lastLineWidth: CGFloat?

  /// Libellé et quantité sur une ligne, avec points de conduite ; libellé replié à gauche d'une colonne de quantité
  /// qui ne se coupe jamais, alignée sur sa dernière ligne avec des points depuis la fin du texte ; ou quantité sous
  /// le libellé.
  private enum Mode {
    case inline, wrapped, stacked
  }

  private struct Arrangement {
    var mode: Mode
    var title: CGSize
    var quantity: CGSize
    var titleBaseline: CGFloat
    var titleLastBaseline: CGFloat
    var quantityBaseline: CGFloat
  }

  private func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
    let title = subviews[0]
    let quantity = subviews.count > 2 ? subviews[2] : nil
    let titleIdeal = title.sizeThatFits(.unspecified)
    let quantityIdeal = quantity?.sizeThatFits(.unspecified) ?? .zero
    let inlineWidth =
      titleIdeal.width + spacing + leaderMinWidth + (quantity == nil ? 0 : spacing + quantityIdeal.width)
    let quantityColumn = quantityIdeal.width + spacing
    let mode: Mode =
      if width.map({ inlineWidth <= $0 }) ?? true {
        .inline
      } else if let width, quantity != nil, quantityIdeal != .zero, quantityColumn <= width * maxQuantityShare {
        .wrapped
      } else {
        .stacked
      }
    let titleProposal =
      switch mode {
      case .inline: ProposedViewSize(titleIdeal)
      // Même largeur qu'en ligne : un libellé qui y tiendrait sur une ligne garde ses points de conduite (mode inline).
      case .wrapped:
        ProposedViewSize(width: max(0, (width ?? 0) - quantityColumn - spacing - leaderMinWidth), height: nil)
      case .stacked: ProposedViewSize(width: width, height: nil)
      }
    let titleSize = mode == .inline ? titleIdeal : title.sizeThatFits(titleProposal)
    // Sous le libellé, la quantité se replie elle aussi plutôt que de déborder de la ligne.
    let quantitySize =
      mode == .stacked ? quantity?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero : quantityIdeal
    let quantityBaseline =
      quantity?.dimensions(in: ProposedViewSize(quantityIdeal))[VerticalAlignment.firstTextBaseline] ?? 0
    return Arrangement(
      mode: mode, title: titleSize, quantity: quantitySize,
      titleBaseline: title.dimensions(in: titleProposal)[VerticalAlignment.firstTextBaseline],
      titleLastBaseline: title.dimensions(in: titleProposal)[VerticalAlignment.lastTextBaseline],
      quantityBaseline: quantityBaseline)
  }

  /// Haut de la quantité : alignée sur la ligne de base du libellé (sa dernière ligne s'il est replié), ou sous lui.
  private func quantityY(_ arrangement: Arrangement) -> CGFloat {
    switch arrangement.mode {
    case .inline: max(0, arrangement.titleBaseline - arrangement.quantityBaseline)
    case .wrapped: max(0, arrangement.titleLastBaseline - arrangement.quantityBaseline)
    case .stacked: arrangement.title.height + stackSpacing
    }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let arrangement = arrange(width: proposal.width, subviews: subviews)
    let hasQuantity = subviews.count > 2 && arrangement.quantity != .zero
    let height = max(
      arrangement.title.height, hasQuantity ? quantityY(arrangement) + arrangement.quantity.height : 0)
    let ideal =
      arrangement.title.width + spacing + leaderMinWidth + (hasQuantity ? spacing + arrangement.quantity.width : 0)
    return CGSize(width: proposal.width ?? ideal, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let arrangement = arrange(width: bounds.width, subviews: subviews)
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(arrangement.title))
    var trailing = bounds.maxX
    if subviews.count > 2 {
      let quantity = arrangement.quantity
      let x = arrangement.mode == .stacked ? bounds.minX : bounds.maxX - quantity.width
      subviews[2].place(
        at: CGPoint(x: x, y: bounds.minY + quantityY(arrangement)), proposal: ProposedViewSize(quantity))
      if quantity != .zero { trailing -= quantity.width + spacing }
    }
    // Points de conduite posés sur la ligne de base du libellé (par leur bas), de la fin du texte à la quantité : sur
    // sa ligne s'il y tient, sur sa dernière ligne s'il est replié (la largeur proposée y réserve leur minimum).
    let leaderX: CGFloat
    let leaderWidth: CGFloat
    let leaderBaseline: CGFloat
    switch arrangement.mode {
    case .inline:
      leaderX = bounds.minX + arrangement.title.width + spacing
      leaderWidth = max(0, trailing - leaderX)
      leaderBaseline = arrangement.titleBaseline
    case .wrapped:
      leaderX = bounds.minX + (lastLineWidth ?? arrangement.title.width) + spacing
      leaderWidth = lastLineWidth == nil ? 0 : max(0, trailing - leaderX)
      leaderBaseline = arrangement.titleLastBaseline
    case .stacked:
      leaderX = bounds.minX
      leaderWidth = 0
      leaderBaseline = arrangement.titleBaseline
    }
    let leaderHeight = subviews[1].sizeThatFits(ProposedViewSize(width: leaderWidth, height: nil)).height
    subviews[1].place(
      at: CGPoint(x: leaderX, y: bounds.minY + leaderBaseline - leaderHeight),
      proposal: ProposedViewSize(width: leaderWidth, height: leaderHeight))
  }

  func explicitAlignment(
    of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGFloat? {
    guard guide == .firstTextBaseline else { return nil }
    return bounds.minY + arrange(width: bounds.width, subviews: subviews).titleBaseline
  }
}

/// Case carrée du ticket : vide, ou pleine d'encre avec une coche de papier.
struct CheckBox: View {
  let isChecked: Bool
  let size: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: TicketMetrics.checkBoxRadius, style: .continuous)
    shape
      .fill(isChecked ? Palette.ink : Color.clear)
      .overlay { shape.strokeBorder(Palette.ink, lineWidth: 2) }
      .overlay {
        Image(systemName: "checkmark")
          .font(.system(size: size * 0.55, weight: .heavy))
          .foregroundStyle(Palette.paper)
          .scaleEffect(isChecked || reduceMotion ? 1 : 0.4)
          .opacity(isChecked ? 1 : 0)
      }
      .frame(width: size, height: size)
      .animation(Motion.check(reduced: reduceMotion), value: isChecked)
      .accessibilityHidden(true)
  }
}

/// Annonces VoiceOver et focus après un réordonnancement (#9 §11).
enum ReorderAnnouncement {
  /// Vrai si les lignes présentes avant et après ne sont plus dans le même ordre relatif.
  /// Un ajout ou un retrait seul n'est pas un réordonnancement.
  static func didReorder(previous: [UUID], current: [UUID]) -> Bool {
    let before = Set(previous)
    let after = Set(current)
    return previous.filter(after.contains) != current.filter(before.contains)
  }

  static func message(next: String?) -> String {
    guard let next else { return "Liste réordonnée." }
    return "Liste réordonnée. Prochain : \(next)."
  }

  /// Ligne qui doit garder le focus VoiceOver : la même, ou sa voisine si elle a quitté la liste.
  static func focusTarget(previous: [UUID], current: [UUID], focused: UUID) -> UUID? {
    if current.contains(focused) { return focused }
    guard let index = previous.firstIndex(of: focused), !current.isEmpty else { return nil }
    return current[min(index, current.count - 1)]
  }

  /// Annonce à priorité basse : elle ne coupe pas la lecture en cours.
  @MainActor static func post(_ text: String) {
    var attributed = AttributedString(text)
    attributed.accessibilitySpeechAnnouncementPriority = .low
    AccessibilityNotification.Announcement(attributed).post()
  }
}
