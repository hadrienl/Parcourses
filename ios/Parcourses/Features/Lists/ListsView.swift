import SwiftUI

/// Écran Listes : état vide, création, renommage, suppression.
struct ListsView: View {
  @State private var model: ListsModel
  let onOpen: (UUID) -> Void

  @State private var isCreating = false
  @State private var renaming: ListSummary?
  @State private var deleting: ListSummary?
  @State private var nameInput = ""
  @State private var showsAbout = false

  init(model: ListsModel, onOpen: @escaping (UUID) -> Void) {
    _model = State(initialValue: model)
    self.onOpen = onOpen
  }

  var body: some View {
    content
      .ticketBackground()
      .navigationTitle("Mes listes")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("À propos", systemImage: "info.circle") { showsAbout = true }
            .accessibilityIdentifier("about")
        }
      }
      .sheet(isPresented: $showsAbout) { AboutView() }
      .safeAreaInset(edge: .bottom) { createButton }
      .opaqueBottomBar()
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
      EmptyState(title: "Aucune liste", systemImage: "cart", description: "Créez votre première liste de courses.")
    } else {
      List(model.lists) { list in
        Button {
          onOpen(list.id)
        } label: {
          row(list)
        }
        .buttonStyle(.plain)
        .ticketRow()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(for: list) }
        .contextMenu { actions(for: list) }
      }
      .listStyle(.plain)
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
    VStack(spacing: 0) {
      HStack(spacing: Space.s) {
        VStack(alignment: .leading, spacing: 2) {
          Text(list.name).font(TicketFont.item.weight(.bold)).foregroundStyle(Palette.ink)
          Text(list.subtitle).font(TicketFont.meta).foregroundStyle(Palette.inkMuted)
        }
        Spacer()
        Image(systemName: "chevron.right").foregroundStyle(Palette.inkMuted).accessibilityHidden(true)
      }
      .padding(.vertical, Space.s)
      .frame(minHeight: TicketMetrics.rowMin)
      // Filet pointillé du ticket entre deux listes.
      DottedRule()
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var createButton: some View {
    Button {
      nameInput = ""
      isCreating = true
    } label: {
      Label("Nouvelle liste", systemImage: "plus")
        .frame(maxWidth: .infinity)
    }
    .prominentButton()
    // Bouton plein flottant, dans la zone du pouce : pas de barre derrière lui.
    .padding(.horizontal, Space.m)
    .padding(.bottom, Space.xs)
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }

  private func isPresented<T>(_ value: Binding<T?>) -> Binding<Bool> {
    Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
  }
}
