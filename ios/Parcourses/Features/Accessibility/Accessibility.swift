import SwiftUI
import UIKit

/// Fond de barre opaque : le contenu qui défile dessous est masqué au lieu de transparaître, ce qui garde le
/// contraste du dock et de la liste (audit d'accessibilité). Le verre revient avec l'habillage du lot 9.11.
private struct BarBackground: ViewModifier {
  func body(content: Content) -> some View {
    content.background(Color(uiColor: .systemBackground)).overlay(alignment: .top) { Divider() }
  }
}

/// Fond de bannière, même règle.
private struct BannerBackground: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    } else {
      content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}

/// Indication du champ de saisie : plus foncée que le gris clair du système, qui ne tient pas 4,5:1.
enum EntryPrompt {
  static var text: Text {
    Text("Ajouter un article").foregroundStyle(Color.primary.opacity(0.6))
  }
}

/// Champ de saisie : la case visible fait au moins 44 pt, et toute la case donne le focus, marges comprises.
private struct EntryFieldStyle: ViewModifier {
  let focus: FocusState<Bool>.Binding

  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .focused(focus)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator)) }
      .contentShape(RoundedRectangle(cornerRadius: 10))
      .onTapGesture { focus.wrappedValue = true }
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

  /// Bouton principal : plein, grande taille (50 pt, sa propre zone tactile). Teinte dédiée, plus sombre que
  /// `AccentColor` en mode sombre, pour que le texte blanc tienne 4,5:1 ; `AccentColor` reste assez clair pour les
  /// liens et pictogrammes sur fond sombre.
  func prominentButton() -> some View {
    buttonStyle(.borderedProminent).controlSize(.large).tint(Color("ProminentTint"))
  }

  /// Liste qui défile sous un dock opaque : pas d'effet de bord de défilement (iOS 26), dont le flou rend
  /// illisible le texte qui passe dessous (l'audit de contraste le rejette, aux grandes tailles de texte).
  @ViewBuilder func opaqueBottomBar() -> some View {
    if #available(iOS 26, *) {
      scrollEdgeEffectHidden(true, for: .bottom)
    } else {
      self
    }
  }

  /// Fond des docks et barres du bas.
  func barBackground() -> some View {
    modifier(BarBackground())
  }

  /// Fond de la bannière « Annuler » et des surimpressions.
  func bannerBackground() -> some View {
    modifier(BannerBackground())
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
    ScrollView {
      VStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.largeTitle)
          .imageScale(.large)
          .foregroundStyle(.tint)
          .padding(.bottom, 8)
          .accessibilityHidden(true)
        Text(title)
          .font(.title2.bold())
          .accessibilityAddTraits(.isHeader)
        Text(description)
          .foregroundStyle(.secondary)
      }
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding()
      .frame(maxWidth: .infinity)
      .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length }
    }
    .scrollBounceBehavior(.basedOnSize)
  }
}

/// Ligne d'article partagée par l'écran Liste et le mode courses.
/// L'état coché se lit sans la couleur : pastille pleine avec coche (forme) et texte barré.
/// Aux grandes tailles de texte, la quantité passe sous le libellé.
struct ItemLine: View {
  let label: String
  let quantity: String?
  let isChecked: Bool
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        marker
        title
        Spacer(minLength: 8)
        quantityText
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          marker
          title
        }
        quantityText.padding(.leading, 32)
      }
    }
    .rowHeight()
  }

  private var marker: some View {
    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
      .foregroundStyle(isChecked ? AnyShapeStyle(Color.accentColor) : secondary)
  }

  private var title: some View {
    Text(label)
      .strikethrough(isChecked)
      // Pas de gris : le texte barré et la coche portent l'état, le contraste reste maximal.
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var quantityText: some View {
    if let quantity {
      Text(quantity).foregroundStyle(secondary)
    }
  }

  /// Contraste augmenté : le texte secondaire repasse en couleur principale.
  private var secondary: AnyShapeStyle {
    contrast == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
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
