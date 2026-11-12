import SwiftUI
import UIKit

/// Indication du champ de saisie : plus foncée que le gris clair du système, qui ne tient pas 4,5:1.
enum EntryPrompt {
  static var text: Text {
    Text("Ajouter un article").foregroundStyle(Palette.inkMuted)
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

/// Bouton plein : accent et texte `onAccent` (8:1 en clair, 7,6:1 en sombre), capsule d'au moins 50 pt.
private struct ProminentButtonStyle: ButtonStyle {
  /// Bouton à pictogramme seul : marges réduites.
  var compact = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
    configuration.label
      .font(.body.weight(.bold))
      // Désactivé : texte secondaire sur le bord du papier ; l'encre en Contraste augmenté, où le fond fonce.
      .foregroundStyle(isEnabled ? Palette.onAccent : (contrast == .increased ? Palette.ink : Palette.inkMuted))
      .padding(.horizontal, compact ? Space.xs / 2 : Space.l)
      .padding(.vertical, Space.xs / 2)
      .frame(minHeight: 50)
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

  /// Bouton principal : plein, à l'accent du ticket, 50 pt au moins (sa propre zone tactile).
  func prominentButton(compact: Bool = false) -> some View {
    buttonStyle(ProminentButtonStyle(compact: compact))
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

  /// Ligne d'une liste habillée en ticket : pas de séparateur, fond de papier, gouttière du fil à gauche.
  func ticketRow(background: Color = Palette.paper) -> some View {
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
/// barré. Aux grandes tailles de texte, les points disparaissent et la quantité passe sous le libellé, qui se replie.
/// La case porte l'accroche du fil (`threadAnchor()`).
struct ItemLine: View {
  let label: String
  let quantity: String?
  let isChecked: Bool
  /// Prochain article du trajet : libellé plus grand et plus gras.
  var isNext = false
  @ScaledMetric(relativeTo: .body) private var box = TicketMetrics.checkBox
  /// Demi-hauteur des capitales du libellé : la case s'aligne sur le milieu de la première ligne.
  @ScaledMetric(relativeTo: .body) private var capHalf: CGFloat = 6
  @ScaledMetric(relativeTo: .title3) private var capHalfNext: CGFloat = 7

  var body: some View {
    // Une seule mise en page, qui garde les mêmes vues quand le texte grandit. `ViewThatFits` remplaçait libellé et
    // quantité par d'autres vues : l'audit Dynamic Type mesurait alors des nœuds qui ne grandissaient pas
    // (« partially unsupported » sur la ligne à quantité).
    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
      checkBox
      LeaderLineLayout(spacing: Space.s, leaderMinWidth: Space.m) {
        title
        DottedRule()
        quantityText
      }
    }
    .padding(.vertical, Space.xs)
    .frame(minHeight: TicketMetrics.rowMin)
    .contentShape(Rectangle())
  }

  private var checkBox: some View {
    let offset = isNext ? capHalfNext : capHalf
    return CheckBox(isChecked: isChecked, size: min(box, 44))
      .threadAnchor()
      .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + offset }
  }

  private var title: some View {
    Text(label)
      .font(isNext ? TicketFont.itemNext : TicketFont.item)
      .strikethrough(isChecked)
      .foregroundStyle(isChecked ? Palette.checked : Palette.ink)
      .fixedSize(horizontal: false, vertical: true)
      // Le libellé passe avant les points de conduite, qui ne prennent que la place restante.
      .layoutPriority(1)
  }

  @ViewBuilder private var quantityText: some View {
    if let quantity {
      Text(quantity).font(TicketFont.quantity).foregroundStyle(Palette.inkMuted)
    }
  }
}

/// Libellé, points de conduite et quantité sur une ligne quand le libellé y tient en entier ; sinon libellé sur
/// plusieurs lignes, quantité dessous et pas de points de conduite. Sous-vues : libellé, points de conduite, puis
/// quantité (facultative). La ligne de base est celle du libellé.
struct LeaderLineLayout: Layout {
  var spacing: CGFloat
  var leaderMinWidth: CGFloat
  /// Écart entre le libellé et la quantité placée dessous.
  var stackSpacing: CGFloat = 2

  private struct Arrangement {
    var inline: Bool
    var title: CGSize
    var quantity: CGSize
    var titleBaseline: CGFloat
    var quantityBaseline: CGFloat
  }

  private func arrange(width: CGFloat?, subviews: Subviews) -> Arrangement {
    let title = subviews[0]
    let quantity = subviews.count > 2 ? subviews[2] : nil
    let titleIdeal = title.sizeThatFits(.unspecified)
    let quantityIdeal = quantity?.sizeThatFits(.unspecified) ?? .zero
    let inlineWidth =
      titleIdeal.width + spacing + leaderMinWidth + (quantity == nil ? 0 : spacing + quantityIdeal.width)
    let inline = width.map { inlineWidth <= $0 } ?? true
    let titleProposal = inline ? ProposedViewSize(titleIdeal) : ProposedViewSize(width: width, height: nil)
    let titleSize = inline ? titleIdeal : title.sizeThatFits(titleProposal)
    let quantityBaseline =
      quantity?.dimensions(in: ProposedViewSize(quantityIdeal))[VerticalAlignment.firstTextBaseline] ?? 0
    return Arrangement(
      inline: inline, title: titleSize, quantity: quantityIdeal,
      titleBaseline: title.dimensions(in: titleProposal)[VerticalAlignment.firstTextBaseline],
      quantityBaseline: quantityBaseline)
  }

  /// Haut de la quantité : alignée sur la ligne de base du libellé, ou sous lui.
  private func quantityY(_ arrangement: Arrangement) -> CGFloat {
    arrangement.inline
      ? max(0, arrangement.titleBaseline - arrangement.quantityBaseline)
      : arrangement.title.height + stackSpacing
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
      let x = arrangement.inline ? bounds.maxX - quantity.width : bounds.minX
      subviews[2].place(
        at: CGPoint(x: x, y: bounds.minY + quantityY(arrangement)), proposal: ProposedViewSize(quantity))
      if quantity != .zero { trailing -= quantity.width + spacing }
    }
    let leaderX = bounds.minX + arrangement.title.width + spacing
    let leaderWidth = arrangement.inline ? max(0, trailing - leaderX) : 0
    // Points de conduite posés sur la ligne de base du libellé (par leur bas), absents quand la quantité passe dessous.
    let leaderHeight = subviews[1].sizeThatFits(ProposedViewSize(width: leaderWidth, height: nil)).height
    subviews[1].place(
      at: CGPoint(x: leaderX, y: bounds.minY + arrangement.titleBaseline - leaderHeight),
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
