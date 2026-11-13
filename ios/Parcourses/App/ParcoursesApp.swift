import SwiftUI

/// Point d'entrée de l'app.
@main
struct ParcoursesApp: App {
  @State private var app = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      switch app.environment {
      case .success(let environment):
        content(environment)
          // Teinte de l'app : l'accent du ticket (8:1 sur le papier en clair), avec sa variante Contraste augmenté.
          // Posée à la racine pour que les feuilles et le plein écran en héritent ; l'asset AccentColor (mêmes
          // valeurs, sans la variante Contraste augmenté) sert aux contrôles système hors de cette hiérarchie (alertes).
          .tint(Palette.accent)
          // Tests UI : apparence et réglages d'affichage forcés (Debug seulement).
          .uiTestOverrides()
      case .failure(let error):
        StoreFailureView(error: error)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active: app.sync?.foreground()
      case .background:
        guard let sync = app.sync else { break }
        sync.enteredBackground()
        SyncRuntime.scheduleBackgroundRefresh()
      default: break
      }
    }
    .backgroundTask(.appRefresh(SyncRuntime.backgroundTaskIdentifier)) {
      await refreshInBackground()
    }
  }

  /// Suppression interrompue par un arrêt de l'app : elle reprend avant tout, sans synchronisation ni connexion.
  @ViewBuilder private func content(_ environment: AppEnvironment) -> some View {
    if app.isResumingDeletion, let deletion = app.deletion {
      AccountDeletionResumeView(deletion: deletion) { app.endDeletionResume() }
    } else {
      RootView(environment: environment)
        .environment(app.deletion)
        .task {
          environment.sync?.start()
          if let gateway = app.gateway {
            await AuthBootstrap.signIn(gateway)
            environment.sync?.sessionDidChange()
          }
        }
        // Après une suppression : environnement neuf, écrans et modèles repartent de zéro.
        .id(app.generation)
    }
  }
}

extension ParcoursesApp {
  private func refreshInBackground() async {
    guard let sync = app.sync else { return }
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
  /// Liste pour laquelle on choisit le magasin.
  @State private var pickingFor: PickerRequest?
  /// Choix fait, en attente de la fermeture de la sheet : deux présentations ne se chevauchent pas.
  @State private var pendingStart: PendingStart?
  @State private var session: ShoppingSession?
  @State private var didResume = false
  /// Préparation en cours (jusqu'à 3 s) : bloque tout second départ, source de visites en double.
  @State private var isStarting = false

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
          // L'identifiant vient du modèle, qui suit la liste : celui de la route a pu changer.
          ListDetailView(model: environment.makeListDetailModel(listId: id)) { listId in
            guard !isStarting, session == nil, pendingStart == nil else { return }
            pickingFor = PickerRequest(listId: listId)
          }
        }
      }
    }
    .overlay {
      if isStarting {
        ZStack {
          Color.black.opacity(0.2).ignoresSafeArea()
          ProgressView("Préparation de vos courses…")
            .padding()
            .parcoursesGlass(in: RoundedRectangle(cornerRadius: TicketMetrics.radius * 2, style: .continuous))
        }
        .accessibilityIdentifier("shoppingPreparation")
      }
    }
    .sheet(item: $pickingFor, onDismiss: beginPendingShopping) { request in
      StorePickerView(
        model: environment.makeStorePickerModel { outcome in
          // Pas `request.listId` : la liste a pu changer d'identifiant pendant le choix.
          pendingStart = PendingStart(listId: pickingFor?.listId ?? request.listId, outcome: outcome)
          pickingFor = nil
        })
    }
    .fullScreenCover(item: $session) { session in
      ShoppingView(session: session) {
        self.session = nil
        // Les écrans déjà ouverts relisent coches, ajouts et retraits.
        NotificationCenter.default.post(name: .syncDidChangeData, object: nil)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountDeletionDidBegin)) { _ in
      // Suppression du compte : le mode courses se ferme sans « Terminer », donc sans clore la visite.
      session = nil
      pickingFor = nil
      pendingStart = nil
    }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidRekeyData)) { notification in
      guard let remap = IdentifierRemap(notification: notification) else { return }
      path = path.map { route in
        switch route {
        case .list(let id): .list(remap[id])
        }
      }
      pickingFor?.listId = remap[pickingFor?.listId ?? UUID()]
      pendingStart?.listId = remap[pendingStart?.listId ?? UUID()]
    }
    .task {
      guard !didResume else { return }
      didResume = true
      isStarting = true
      session = await environment.resumeShopping()
      environment.endOrphanActivities(keeping: session?.visitId)
      isStarting = false
    }
  }

  private func beginPendingShopping() {
    guard let start = pendingStart else { return }
    pendingStart = nil
    isStarting = true
    var storeId: UUID?
    if case .store(let id) = start.outcome { storeId = id }
    // Créée avant toute suspension : dès cet instant, la session suit un changement d'identifiant.
    let prepared = environment.makeSession(listId: start.listId, storeId: storeId)
    Task {
      await prepared.start()
      session = prepared
      isStarting = false
    }
  }
}

private struct PickerRequest: Identifiable {
  /// Distinct de `listId` : un changement d'identifiant de la liste ne doit pas rouvrir la sheet.
  let id = UUID()
  var listId: UUID
}

private struct PendingStart {
  var listId: UUID
  let outcome: StorePickerOutcome
}
