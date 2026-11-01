import SwiftUI
import UIKit

/// Choix du magasin, présenté en sheet par le mode courses (9.9).
struct StorePickerView: View {
  @State var model: StorePickerModel
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Choisir le magasin")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { attribution }
        .alert("Impossible d'enregistrer ce magasin", isPresented: selectionFailed) {
          Button("OK", role: .cancel) {}
        } message: {
          Text("Réessayez, ou continuez sans magasin.")
        }
    }
    .task { await model.load() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await model.refreshAfterForeground() } }
    }
  }

  private var selectionFailed: Binding<Bool> {
    Binding(get: { model.selectionFailed }, set: { if !$0 { model.dismissSelectionFailure() } })
  }

  @ViewBuilder private var content: some View {
    switch model.state {
    case .loading:
      ProgressView("Recherche des magasins proches…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .precise(let proposed, let others):
      List {
        if let proposed {
          Section("Vous êtes ici ?") {
            StoreRow(store: proposed) { model.select(proposed) }
            Button("Faire mes courses ici") { model.select(proposed) }
              .buttonStyle(.borderedProminent)
              .frame(maxWidth: .infinity)
              .listRowBackground(Color.clear)
              .accessibilityIdentifier("confirmProposal")
          }
        }
        stores(others, title: proposed == nil ? "Magasins proches" : "Autres magasins proches")
        recentsSection
      }
    case .approximate(let candidates):
      List {
        Section {
          Label("Votre position est approximative : choisissez votre magasin.", systemImage: "location.circle")
          Button("Utiliser ma position précise") { Task { await model.requestPrecision() } }
        }
        searchSection
        if !isSearching { stores(candidates, title: "Magasins dans le secteur") }
        recentsSection
      }
    case .denied:
      fallbackList(
        title: "Localisation désactivée",
        message: "Cherchez votre magasin par nom ou par ville.", systemImage: "location.slash"
      ) {
        Button("Ouvrir les Réglages") {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
      }
    case .locationUnavailable:
      fallbackList(
        title: "Position introuvable", message: "Cherchez votre magasin par nom ou par ville.",
        systemImage: "location.magnifyingglass"
      ) { retry }
    case .offline:
      fallbackList(
        title: "Hors ligne", message: "Choisissez un magasin récent, ou continuez sans magasin.",
        systemImage: "wifi.slash"
      ) { retry }
    case .serviceError:
      fallbackList(
        title: "Service indisponible", message: "Les magasins proches n'ont pas pu être chargés.",
        systemImage: "exclamationmark.icloud"
      ) { retry }
    case .noStore:
      fallbackList(
        title: "Aucun magasin connu ici", message: "Cherchez-le par nom, ou continuez sans magasin.",
        systemImage: "mappin.slash"
      ) { EmptyView() }
    }
  }

  private var retry: some View {
    Button("Réessayer") { Task { await model.load() } }
  }

  private var isSearching: Bool {
    model.search != .idle
  }

  /// États sans magasin proche : explication, recherche si possible, récents, puis sortie sans magasin.
  private func fallbackList(
    title: String, message: String, systemImage: String, @ViewBuilder action: () -> some View
  ) -> some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Label(title, systemImage: systemImage).font(.headline)
          Text(message).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        action()
      }
      if model.offersSearch { searchSection }
      recentsSection
      Section {
        Button("Continuer sans magasin") { model.continueWithoutStore() }
          .accessibilityIdentifier("continueWithoutStore")
      } footer: {
        Text("La liste suivra l'ordre générique des rayons.")
      }
    }
  }

  @ViewBuilder private var searchSection: some View {
    Section {
      TextField("Nom du magasin ou ville", text: $model.query, prompt: Text("Nom du magasin ou ville"))
        .textInputAutocapitalization(.words)
        .autocorrectionDisabled()
        .accessibilityIdentifier("storeSearch")
      switch model.search {
      case .idle:
        EmptyView()
      case .searching:
        ProgressView()
      case .results(let found) where found.isEmpty:
        Text("Aucun magasin trouvé.").foregroundStyle(.secondary)
      case .results(let found):
        ForEach(found) { store in StoreRow(store: store) { model.select(store) } }
      case .offline:
        Text("Recherche impossible hors ligne.").foregroundStyle(.secondary)
      case .failed:
        Text("La recherche a échoué. Réessayez.").foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var recentsSection: some View {
    stores(model.recents, title: "Récents")
  }

  @ViewBuilder private func stores(_ stores: [StoreCandidate], title: String) -> some View {
    if !stores.isEmpty {
      Section(title) {
        ForEach(stores) { store in StoreRow(store: store) { model.select(store) } }
      }
    }
  }

  /// Les magasins viennent d'OpenStreetMap (#9 §8).
  private var attribution: some View {
    Text("© contributeurs OpenStreetMap")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
      .background(.bar)
  }
}

/// Ligne de magasin : nom, adresse et distance si elle a un sens.
private struct StoreRow: View {
  let store: StoreCandidate
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(store.name).foregroundStyle(.primary)
          if let address = store.address {
            Text(address).font(.subheadline).foregroundStyle(.secondary)
          }
        }
        Spacer()
        if let distance = store.distanceM {
          Text(StoreDistance.text(metres: distance)).font(.subheadline).foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    // Style neutre : le nom se lit comme un contenu, pas comme un lien teinté.
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}

/// Distance lisible et arrondie : le GPS ne justifie pas le mètre près.
nonisolated enum StoreDistance {
  static func text(metres: Double) -> String {
    if metres < 1000 { return "\(Int((metres / 10).rounded()) * 10) m" }
    let kilometres = (metres / 100).rounded() / 10
    return kilometres.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "fr_FR"))) + " km"
  }
}
