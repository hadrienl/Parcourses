import SwiftUI

/// Écran Liste : articles groupés par rayon, saisie rapide dans un dock en bas.
struct ListDetailView: View {
  @State private var model: ListDetailModel
  @FocusState private var inputIsFocused: Bool

  init(model: ListDetailModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    List {
      ForEach(model.sections) { section in
        Section(section.title) {
          ForEach(section.items) { row in
            itemRow(row)
          }
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
    .safeAreaInset(edge: .bottom) {
      if !model.isMissing { dock }
    }
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
      HStack {
        // L'état se lit sans couleur : forme de l'icône et texte barré.
        Image(systemName: row.isChecked ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(row.isChecked ? Color.accentColor : .secondary)
        Text(row.label)
          .strikethrough(row.isChecked)
          .foregroundStyle(row.isChecked ? .secondary : .primary)
        Spacer()
        if let quantity = row.quantity {
          Text(quantity).foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 48)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityState)
    .accessibilityAddTraits(.isToggle)
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
                .accessibilityLabel("Ajouter \(suggestion.label)")
            }
          }
        }
      }
      HStack {
        TextField("Ajouter un article", text: $model.input)
          .textFieldStyle(.roundedBorder)
          .focused($inputIsFocused)
          .submitLabel(.done)
          .accessibilityIdentifier("quickEntry")
          .onSubmit(submit)
        Button("Ajouter", systemImage: "plus.circle.fill", action: submit)
          .labelStyle(.iconOnly)
          .font(.title)
          .frame(minWidth: 44, minHeight: 44)
          .disabled(model.input.allSatisfy(\.isWhitespace))
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
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
