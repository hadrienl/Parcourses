import SwiftUI

/// Une ligne du ticket de l'écran Liste : le nœud d'un rayon, ou un article.
private enum ListLine: Identifiable {
  case aisle(ItemSection)
  case item(ItemRow)

  var id: String {
    switch self {
    case .aisle(let section): "aisle:\(section.id)"
    case .item(let row): row.id.uuidString
    }
  }
}

/// Écran Liste : ticket groupé par rayon sur le fil (encore à parcourir), saisie rapide dans un dock en verre en bas.
struct ListDetailView: View {
  @State private var model: ListDetailModel
  @FocusState private var inputIsFocused: Bool
  @ScaledMetric(relativeTo: .largeTitle) private var totalSize: CGFloat = 52
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
    let lines = model.sections.flatMap { section in
      [ListLine.aisle(section)] + section.items.map(ListLine.item)
    }
    // Écran de préparation : le fil est tracé, rien n'est encore parcouru.
    let places = ThreadPlace.places(count: lines.count, reached: nil, progress: false)
    List {
      if !model.isEmpty {
        header.ticketRow()
      }
      ForEach(Array(zip(lines, places)), id: \.0.id) { line, place in
        switch line {
        case .aisle(let section):
          aisleRow(section, place: place).ticketRow()
        case .item(let row):
          itemRow(row, place: place)
        }
      }
    }
    .listStyle(.plain)
    .ticketBackground()
    .environment(\.defaultMinListRowHeight, 0)
    // Repère des tests UI (audit d'accessibilité) : la liste de l'écran Liste.
    .accessibilityIdentifier("itemList")
    .scrollDismissesKeyboard(.interactively)
    .overlay {
      if model.isMissing {
        EmptyState(
          title: "Liste introuvable", systemImage: "questionmark.folder", description: "Cette liste a été supprimée.")
      } else if model.isLoaded && model.isEmpty {
        EmptyState(
          title: "Liste vide", systemImage: "basket",
          description: "Ajoutez un article, par exemple « 2 laits demi-écrémé ».")
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
    .opaqueBottomBar()
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

  /// Compteur du ticket : « ARTICLES 06 ».
  private var header: some View {
    let count = model.sections.reduce(0) { $0 + $1.items.count }
    return HStack(alignment: .lastTextBaseline) {
      Text("Articles")
        .font(TicketFont.totalCaption)
        .tracking(TicketFont.aisleTracking)
        .textCase(.uppercase)
        .foregroundStyle(Palette.inkMuted)
      Spacer(minLength: Space.s)
      Text(ShoppingView.counter(count))
        .font(TicketFont.total(size: totalSize))
        .monospacedDigit()
        .foregroundStyle(Palette.ink)
    }
    .padding(.top, Space.xs)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(count <= 1 ? "\(count) article" : "\(count) articles")
  }

  /// Nœud d'un rayon sur le fil, lu comme un en-tête.
  private func aisleRow(_ section: ItemSection, place: ThreadPlace) -> some View {
    AisleLine(
      aisleId: section.categoryId, title: section.title, identifier: "aisle-\(section.categoryId)", place: place)
  }

  private func itemRow(_ row: ItemRow, place: ThreadPlace) -> some View {
    Button {
      model.toggle(row)
    } label: {
      ThreadRow(place: place) {
        // Préparation : rien n'est parcouru, la case seule porte l'état coché.
        Bead(state: .idle)
      } content: {
        // L'état se lit sans couleur : case pleine avec coche, et texte barré.
        ItemLine(label: row.label, quantity: row.quantity, isChecked: row.isChecked)
      }
    }
    .buttonStyle(.plain)
    .ticketRow()
    .accessibilityElement(children: .combine)
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(row.accessibilityState)
    .accessibilityHint(row.isChecked ? "Décoche l'article" : "Coche l'article")
    .accessibilityAddTraits(.isToggle)
    .accessibilityActions {
      if row.isChecked { Button("Décocher") { model.toggle(row) } }
    }
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
              Button {
                model.add(suggestion)
              } label: {
                Text(suggestion.label)
                  .font(.system(.body, design: .monospaced).weight(.medium))
                  .foregroundStyle(Palette.ink)
                  .padding(.horizontal, Space.m)
                  .touchTarget()
                  .background(Palette.paper, in: Capsule())
                  .overlay { Capsule().strokeBorder(Palette.paperEdge) }
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Ajouter \(suggestion.label)")
              .accessibilityIdentifier("suggestion")
            }
          }
        }
      }
      HStack {
        TextField("Ajouter un article", text: $model.input, prompt: EntryPrompt.text)
          .entryField(focus: $inputIsFocused)
          .submitLabel(.done)
          .accessibilityIdentifier("quickEntry")
          .onSubmit(submit)
        Button(action: submit) {
          Label("Ajouter", systemImage: "plus")
            .labelStyle(.iconOnly)
            .font(.title3.weight(.bold))
            .frame(minWidth: 44)
            .touchTarget()
        }
        .prominentButton(compact: true)
        .disabled(model.input.allSatisfy(\.isWhitespace))
        .accessibilityIdentifier("addItem")
      }
    }
    .floatingDock()
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
