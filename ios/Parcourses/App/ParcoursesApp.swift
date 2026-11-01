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
        StoreFailureView(error: error)
      }
    }
  }
}

/// Écran d'échec d'ouverture du store : dit quoi faire et rassure sur les données.
struct StoreFailureView: View {
  let error: any Error

  var body: some View {
    ContentUnavailableView(
      "Impossible d'ouvrir vos listes", systemImage: "exclamationmark.triangle",
      description: Text(Self.message(for: error)))
  }

  static func message(for error: any Error) -> String {
    let localized = error as? any LocalizedError
    let advice =
      localized?.recoverySuggestion
      ?? "Fermez l'app puis rouvrez-la. Si le problème persiste, redémarrez l'iPhone ou installez une version à jour."
    let reassurance = "Aucune liste n'a été supprimée."
    return [error.localizedDescription, advice, reassurance].joined(separator: "\n\n")
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
      ListsView(model: environment.makeListsModel()) { id in
        // Un double appui ne doit pas empiler deux fois le même écran.
        guard path.last != .list(id) else { return }
        path.append(.list(id))
      }
      .navigationDestination(for: Route.self) { route in
        switch route {
        case .list(let id):
          ListDetailView(model: environment.makeListDetailModel(listId: id))
        }
      }
    }
  }
}
