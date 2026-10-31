import Domain
import SortEngine
import SwiftUI

/// Point d'entrée de l'app. Au lot 9.1, un écran vide.
@main
struct ParcoursesApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}

/// Écran racine provisoire, remplacé par la navigation réelle (9.4 et suivants).
struct RootView: View {
  var body: some View {
    Color.clear
      .accessibilityIdentifier("root")
  }
}
