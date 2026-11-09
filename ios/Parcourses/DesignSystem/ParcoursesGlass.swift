import SwiftUI

/// Matière de la barre basse flottante (saisie et « Terminer ») (#9 §14, jeton `material.ios26`). Le ticket, lui,
/// reste opaque : le verre est réservé à la couche de contrôle. Les bannières (« Annuler ») sont en papier
/// (`ticketBanner()`).
/// - iOS 26+ : Liquid Glass (`glassEffect(.regular)`).
/// - iOS 18 : `.regularMaterial` et un filet de 0,5 pt.
/// - Réduire la transparence ou Contraste augmenté : papier opaque et filet, sur toutes les versions. Le verre laisse
///   transparaître la liste qui défile dessous : le texte posé dessus n'y tient pas le contraste renforcé.
private struct ParcoursesGlass<S: InsettableShape>: ViewModifier {
  let shape: S
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    if reduceTransparency || contrast == .increased {
      // Réduire la transparence : aplat du bord du papier, qui détache le dock du ticket. Contraste augmenté : papier,
      // sur lequel l'accent garde 7:1, et filet foncé.
      content
        .background(contrast == .increased ? Palette.paper : Palette.paperEdge, in: shape)
        .overlay { shape.strokeBorder(Palette.paperEdge, lineWidth: contrast == .increased ? 1 : 0.5) }
    } else if #available(iOS 26, *) {
      content.glassEffect(.regular, in: shape)
    } else {
      content
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(Palette.paperEdge, lineWidth: 0.5) }
    }
  }
}

extension View {
  /// Verre de Parcourses, avec ses replis (iOS 18, Réduire la transparence).
  func parcoursesGlass<S: InsettableShape>(in shape: S) -> some View {
    modifier(ParcoursesGlass(shape: shape))
  }

  /// Verre d'une barre flottante : capsule tant qu'elle tient sur une ligne, coins de 28 pt quand elle s'empile.
  func parcoursesGlass() -> some View {
    parcoursesGlass(in: RoundedRectangle(cornerRadius: TicketMetrics.primaryAction / 2, style: .continuous))
  }
}
