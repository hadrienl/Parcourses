import SwiftUI
import UIKit

/// Hauteur minimale qui grandit avec Dynamic Type : jamais de hauteur fixe (#9 §11).
private struct ScaledMinHeight: ViewModifier {
  @ScaledMetric(relativeTo: .body) private var height = 44.0

  init(_ base: Double) {
    _height = ScaledMetric(wrappedValue: base, relativeTo: .body)
  }

  func body(content: Content) -> some View {
    content.frame(minHeight: height)
  }
}

/// Fond de barre : le matériau du système, ou un aplat opaque avec « Réduire la transparence ».
private struct BarBackground: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color(uiColor: .systemBackground)).overlay(alignment: .top) { Divider() }
    } else {
      content.background(.bar)
    }
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

/// Champ de saisie : la zone visible fait au moins 44 pt, pas seulement la zone tactile.
private struct EntryFieldStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .textFieldStyle(.plain)
      .padding(.horizontal, 12)
      .touchTarget()
      .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
      .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(uiColor: .separator)) }
  }
}

extension View {
  /// Champ de saisie rapide du dock.
  func entryField() -> some View {
    modifier(EntryFieldStyle())
  }

  /// Cible tactile d'au moins 44 pt (48 pt pour les lignes), à l'échelle du texte.
  func touchTarget(minHeight: Double = 44) -> some View {
    modifier(ScaledMinHeight(minHeight))
  }

  /// Ligne : 48 pt au moins.
  func rowHeight() -> some View {
    modifier(ScaledMinHeight(48))
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
    .contentShape(Rectangle())
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
