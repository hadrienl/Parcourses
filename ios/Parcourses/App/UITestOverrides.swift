import SwiftUI
import UIKit

extension View {
  /// Tests UI : apparence et réglages d'affichage forcés par l'environnement de lancement, pour l'audit
  /// d'accessibilité. Les variables ne sont lues qu'en Debug ; en Release, la vue est rendue telle quelle.
  @ViewBuilder func uiTestOverrides() -> some View {
    #if DEBUG
      modifier(UITestOverrides(variables: ProcessInfo.processInfo.environment))
    #else
      self
    #endif
  }
}

#if DEBUG
  /// - `PARCOURSES_TEST_COLOR_SCHEME=dark` : mode sombre (`XCUIDevice.appearance` ne s'applique pas de façon
  ///   fiable au simulateur).
  /// - `PARCOURSES_TEST_INCREASE_CONTRAST=1` : Contraste augmenté, posé sur les traits de la scène. Les couleurs
  ///   système passent à leur variante contrastée et SwiftUI lit `colorSchemeContrast == .increased`, feuilles et
  ///   plein écran compris. Un test UI ne peut pas changer le réglage du simulateur (`simctl ui` se lance depuis
  ///   le Mac, pas depuis le test).
  /// - `PARCOURSES_TEST_REDUCE_TRANSPARENCY=1` : Réduire la transparence, vu par nos vues
  ///   (`accessibilityReduceTransparency`). Les barres système gardent leur rendu : aucun trait ni réglage
  ///   accessible au test ne les change.
  private struct UITestOverrides: ViewModifier {
    let variables: [String: String]

    func body(content: Content) -> some View {
      content
        .preferredColorScheme(variables["PARCOURSES_TEST_COLOR_SCHEME"] == "dark" ? .dark : nil)
        .transformEnvironment(\._accessibilityReduceTransparency) { value in
          if variables["PARCOURSES_TEST_REDUCE_TRANSPARENCY"] != nil { value = true }
        }
        .background {
          if variables["PARCOURSES_TEST_INCREASE_CONTRAST"] != nil { IncreasedContrast() }
        }
    }
  }

  /// Pose le contraste élevé sur la scène qui affiche la vue.
  private struct IncreasedContrast: UIViewRepresentable {
    func makeUIView(context: Context) -> SceneTraitView { SceneTraitView() }
    func updateUIView(_ uiView: SceneTraitView, context: Context) {}

    final class SceneTraitView: UIView {
      override func didMoveToWindow() {
        super.didMoveToWindow()
        window?.windowScene?.traitOverrides.accessibilityContrast = .high
      }
    }
  }
#endif
