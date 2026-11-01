import SwiftUI

/// Point d'entrée de l'app.
@main
struct ParcoursesApp: App {
  /// Une erreur ici (store illisible, App Group absent) s'affiche : on ne repart jamais sur un store vide en silence.
  @State private var environment: Result<AppEnvironment, any Error>
  @Environment(\.scenePhase) private var scenePhase
  private let gateway: (any RemoteGateway)?

  init() {
    let gateway = AuthBootstrap.makeGateway()
    self.gateway = gateway
    _environment = State(initialValue: Result { try AppEnvironment.live(gateway: gateway) })
  }

  private var sync: SyncRuntime? {
    try? environment.get().sync
  }

  var body: some Scene {
    WindowGroup {
      switch environment {
      case .success(let environment):
        RootView(environment: environment)
          .task {
            environment.sync?.start()
            if let gateway {
              await AuthBootstrap.signIn(gateway)
              environment.sync?.sessionDidChange()
            }
          }
      case .failure(let error):
        StoreFailureView(error: error)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: sync?.foreground()
      case .background:
        guard let sync else { break }
        sync.enteredBackground()
        SyncRuntime.scheduleBackgroundRefresh()
      default: break
      }
    }
    .backgroundTask(.appRefresh(SyncRuntime.backgroundTaskIdentifier)) {
      await refreshInBackground()
    }
  }
}

extension ParcoursesApp {
  private func refreshInBackground() async {
    guard let sync else { return }
    // Une seule tâche planifiée à la fois : la suivante se demande ici.
    SyncRuntime.scheduleBackgroundRefresh()
    await sync.backgroundRefresh()
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
