import SwiftUI

/// Écran Listes : état vide, création, renommage, suppression.
struct ListsView: View {
  @State private var model: ListsModel
  let onOpen: (UUID) -> Void

  @State private var isCreating = false
  @State private var renaming: ListSummary?
  @State private var deleting: ListSummary?
  @State private var nameInput = ""

  init(model: ListsModel, onOpen: @escaping (UUID) -> Void) {
    _model = State(initialValue: model)
    self.onOpen = onOpen
  }

  var body: some View {
    content
      .navigationTitle("Mes listes")
      .safeAreaInset(edge: .bottom) { createButton }
      // Relancé à chaque retour sur l'écran, pour des compteurs à jour.
      .task { model.load() }
      .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in model.load() }
      .alert("Nouvelle liste", isPresented: $isCreating) {
        TextField("Nom de la liste", text: $nameInput)
        Button("Annuler", role: .cancel) { isCreating = false }
        Button("Créer") {
          if let id = model.create(name: nameInput) { onOpen(id) }
        }
        .disabled(!ListsModel.isValid(name: nameInput))
      }
      .alert("Renommer la liste", isPresented: isPresented($renaming), presenting: renaming) { list in
        TextField("Nom de la liste", text: $nameInput)
        Button("Annuler", role: .cancel) { renaming = nil }
        Button("Renommer") { model.rename(id: list.id, name: nameInput) }
          .disabled(!ListsModel.isValid(name: nameInput))
      }
      .confirmationDialog(
        "Supprimer cette liste et ses articles ?", isPresented: isPresented($deleting), titleVisibility: .visible,
        presenting: deleting
      ) { list in
        Button("Supprimer la liste", role: .destructive) { model.delete(id: list.id) }
      }
      .alert("Erreur", isPresented: errorIsPresented) {
        Button("OK", role: .cancel) { model.errorMessage = nil }
      } message: {
        Text(model.errorMessage ?? "")
      }
  }

  @ViewBuilder private var content: some View {
    if model.lists.isEmpty {
      ContentUnavailableView(
        "Aucune liste", systemImage: "cart",
        description: Text("Créez votre première liste de courses."))
    } else {
      List(model.lists) { list in
        Button {
          onOpen(list.id)
        } label: {
          row(list)
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(for: list) }
        .contextMenu { actions(for: list) }
      }
    }
  }

  @ViewBuilder private func actions(for list: ListSummary) -> some View {
    Button("Supprimer", systemImage: "trash", role: .destructive) { deleting = list }
    Button("Renommer", systemImage: "pencil") {
      nameInput = list.name
      renaming = list
    }
  }

  private func row(_ list: ListSummary) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(list.name).font(.headline)
        Text(list.subtitle).font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
    }
    .frame(minHeight: 48)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var createButton: some View {
    Button {
      nameInput = ""
      isCreating = true
    } label: {
      Label("Nouvelle liste", systemImage: "plus")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .padding()
    .background(.bar)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}
