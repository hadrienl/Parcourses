import SwiftUI

/// Écran Liste : articles groupés par rayon, saisie rapide dans un dock en bas.
struct ListDetailView: View {
  @State private var model: ListDetailModel
  @FocusState private var inputIsFocused: Bool
  private let onShop: (UUID) -> Void

  init(
    model: ListDetailModel,
    onShop: @escaping (UUID) -> Void = { _ in
      // Sans navigation : aperçus et tests.
    }
  ) {
    _model = State(initialValue: model)
    self.onShop = onShop
  }

  var body: some View {
    List {
      ForEach(model.sections) { section in
        Section {
          ForEach(section.items) { row in
            itemRow(row)
          }
        } header: {
          // Titre en couleur principale : le gris des en-têtes du système tient mal le contraste.
          Text(section.title).foregroundStyle(.primary)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .overlay {
      if model.isMissing {
        ContentUnavailableView(
          "Liste introuvable", systemImage: "questionmark.folder",
          description: Text("Cette liste a été supprimée."))
      } else if model.isLoaded && model.isEmpty {
        ContentUnavailableView(
          "Liste vide", systemImage: "basket",
          description: Text("Ajoutez un article, par exemple « 2 laits demi-écrémé »."))
      }
    }
    .navigationTitle(model.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        if !model.isMissing {
          Button("Faire mes courses", systemImage: "cart") { onShop(model.listId) }
            .labelStyle(.titleAndIcon)
            .disabled(model.isEmpty)
            .accessibilityIdentifier("startShopping")
        }
      }
    }
    .safeAreaInset(edge: .bottom) {
      if !model.isMissing { dock }
    }
    .onReceive(NotificationCenter.default.publisher(for: .syncDidChangeData)) { _ in model.load() }
    .task {
      model.load()
      inputIsFocused = model.isEmpty && !model.isMissing
    }
    .alert("Erreur", isPresented: errorIsPresented) {
      Button("OK", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private func itemRow(_ row: ItemRow) -> some View {
    Button {
      model.toggle(row)
    } label: {
      // L'état se lit sans couleur : forme de l'icône et texte barré.
      ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityState)
    .accessibilityHint(row.isChecked ? "Décoche l'article" : "Coche l'article")
    .accessibilityAddTraits(.isToggle)
    .accessibilityAction(named: "Décocher") { if row.isChecked { model.toggle(row) } }
    .sensoryFeedback(.success, trigger: row.isChecked) { _, checked in checked }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button("Supprimer", systemImage: "trash", role: .destructive) { model.delete(row) }
    }
  }

  private var dock: some View {
    VStack(spacing: 8) {
      let suggestions = model.suggestions
      if !suggestions.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(suggestions) { suggestion in
              Button(suggestion.label) { model.add(suggestion) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .touchTarget()
                .accessibilityLabel("Ajouter \(suggestion.label)")
            }
          }
        }
      }
      HStack {
        TextField("Ajouter un article", text: $model.input)
          .entryField()
          .focused($inputIsFocused)
          .submitLabel(.done)
          .accessibilityIdentifier("quickEntry")
          .onSubmit(submit)
        Button("Ajouter", systemImage: "plus.circle.fill", action: submit)
          .labelStyle(.iconOnly)
          .font(.title)
          .frame(minWidth: 44)
          .touchTarget()
          .disabled(model.input.allSatisfy(\.isWhitespace))
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .barBackground()
  }

  /// Le clavier reste ouvert : on enchaîne les articles.
  private func submit() {
    model.submit()
    inputIsFocused = true
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
  }
}
