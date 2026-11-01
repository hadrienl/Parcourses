import SwiftUI

/// Point d'entrée de l'app.
@main
struct ParcoursesApp: App {
  /// Une erreur ici (store illisible, App Group absent) s'affiche : on ne repart jamais sur un store vide en silence.
  @State private var environment = Result { try AppEnvironment.live() }

  var body: some Scene {
    WindowGroup {
      switch environment {
      case .success(let environment):
        RootView(environment: environment)
      case .failure(let error):
        ContentUnavailableView(
          "Impossible d'ouvrir vos listes", systemImage: "exclamationmark.triangle",
          description: Text(String(describing: error)))
      }
    }
  }
}

/// Routes de la pile de navigation (#9 §9). Les suivantes arrivent avec leurs écrans.
enum Route: Hashable {
  case list(UUID)
}

/// Racine : une seule `NavigationStack`, un seul point de destination.
struct RootView: View {
  let environment: AppEnvironment
  @State private var path: [Route] = []

  var body: some View {
    NavigationStack(path: $path) {
      ListsView(model: environment.makeListsModel()) { path.append(.list($0)) }
        .navigationDestination(for: Route.self) { route in
          switch route {
          case .list(let id):
            ListDetailView(model: environment.makeListDetailModel(listId: id))
          }
        }
    }
    .accessibilityIdentifier("root")
  }
}
