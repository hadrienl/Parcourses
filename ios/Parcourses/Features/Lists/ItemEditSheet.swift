import Domain
import SwiftUI

/// Article ouvert dans le panneau (#110) : appui long sur une ligne de la liste, ou « Quantité » du mode courses.
struct ItemEditTarget: Identifiable, Equatable {
  let id: UUID
  let label: String
  let quantity: String?
}

/// Ce que le panneau enregistre : libellé sans blancs de bord, quantité nettoyée (`ItemQuantity.quantityInput`).
struct ItemEdit: Equatable {
  let label: String
  let quantity: String?

  /// Valeurs du formulaire ; `nil` si le libellé est vide.
  init?(label: String, quantityText: String) {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    self.label = String(trimmed.prefix(ItemEdit.maxLabelLength))
    quantity = ItemQuantity.quantityInput(quantityText)
  }

  /// `list_items.label` : 200 caractères au plus.
  static let maxLabelLength = 200
}

extension ListRepository {
  /// Enregistre le panneau : le libellé est reclassé comme à l'ajout (forme normalisée et rayon), sans en extraire de
  /// quantité. Même chemin pour l'écran Liste et le mode courses.
  func apply(_ edit: ItemEdit, to itemId: UUID, analyzer: EntryAnalyzer, at date: Date) throws {
    let entry = analyzer.analyze(label: edit.label)
    try updateItem(
      itemId: itemId, label: entry.label, normalizedName: entry.normalizedName, categoryId: entry.categoryId,
      quantity: edit.quantity, at: date)
  }
}

/// Panneau de l'article, à mi-hauteur : libellé modifiable, − / + sur le nombre, raccourcis g / kg / l, champ libre de
/// quantité et « Effacer la quantité ». Rien n'est écrit avant « Enregistrer » ; fermer la feuille annule.
struct ItemEditSheet: View {
  let target: ItemEditTarget
  let onSave: (ItemEdit) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var label: String
  @State private var quantityText: String

  init(target: ItemEditTarget, onSave: @escaping (ItemEdit) -> Void) {
    self.target = target
    self.onSave = onSave
    _label = State(initialValue: target.label)
    _quantityText = State(initialValue: target.quantity ?? "")
  }

  private var quantity: String? { ItemQuantity.quantityInput(quantityText) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Space.l) {
          labelSection
          quantitySection
        }
        .padding(Space.m)
      }
      .ticketBackground()
      .navigationTitle("Article")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Annuler") { dismiss() }
            .accessibilityIdentifier("cancelItem")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Enregistrer", action: save)
            .disabled(ItemEdit(label: label, quantityText: quantityText) == nil)
            .accessibilityIdentifier("saveItem")
        }
      }
    }
    .presentationDetents([.medium, .large])
    // Fond opaque : le verre de la feuille laisse transparaître la liste et dégrade le contraste.
    .presentationBackground(Palette.paper)
    .accessibilityIdentifier("itemSheet")
  }

  private var labelSection: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      sectionTitle("Libellé")
      TextField("Libellé", text: $label)
        .sheetField()
        .submitLabel(.done)
        .onChange(of: label) { _, value in
          if value.count > ItemEdit.maxLabelLength { label = String(value.prefix(ItemEdit.maxLabelLength)) }
        }
        .accessibilityIdentifier("itemLabelField")
    }
  }

  private var quantitySection: some View {
    VStack(alignment: .leading, spacing: Space.s) {
      sectionTitle("Quantité")
      HStack(spacing: Space.s) {
        stepButton(delta: -1, systemImage: "minus", label: "Diminuer la quantité", identifier: "quantityDecrement")
        TextField("Quantité", text: $quantityText, prompt: Text("ex.\u{00A0}: 500 g").foregroundStyle(Palette.inkMuted))
          .sheetField()
          .multilineTextAlignment(.center)
          .submitLabel(.done)
          .onChange(of: quantityText) { _, value in
            if value.count > ItemQuantity.maxLength { quantityText = String(value.prefix(ItemQuantity.maxLength)) }
          }
          .accessibilityIdentifier("quantityField")
        stepButton(delta: 1, systemImage: "plus", label: "Augmenter la quantité", identifier: "quantityIncrement")
      }
      HStack(spacing: Space.s) {
        ForEach(QuantityUnit.allCases, id: \.self) { unit in unitChip(unit) }
      }
      Button {
        quantityText = ""
      } label: {
        Label("Effacer la quantité", systemImage: "xmark.circle")
          .font(.body.weight(.semibold))
          .touchTarget()
      }
      .disabled(quantity == nil)
      .accessibilityIdentifier("clearQuantity")
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(TicketFont.aisle)
      .tracking(TicketFont.aisleTracking)
      .textCase(.uppercase)
      .foregroundStyle(Palette.inkMuted)
      .accessibilityHidden(true)
  }

  private func stepButton(delta: Int, systemImage: String, label: String, identifier: String) -> some View {
    let next = ItemQuantity.stepQuantity(quantity, delta: delta)
    return Button {
      if let next { quantityText = next }
    } label: {
      Image(systemName: systemImage)
        .font(.title3.weight(.bold))
        .frame(minWidth: 44, minHeight: 44)
        .background(Palette.paperEdge, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(next == nil ? Palette.inkMuted : Palette.ink)
    .disabled(next == nil)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }

  private func unitChip(_ unit: QuantityUnit) -> some View {
    let next = ItemQuantity.setQuantityUnit(quantity, unit: unit)
    let selected = ItemQuantity.quantityUnit(quantity) == unit
    return Button {
      if let next { quantityText = next }
    } label: {
      Text(unit.rawValue)
        .font(.system(.body, design: .monospaced).weight(.semibold))
        .foregroundStyle(selected ? Palette.paper : (next == nil ? Palette.inkMuted : Palette.ink))
        .frame(minWidth: 56)
        .touchTarget()
        .background(selected ? Palette.ink : Palette.paper, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.ink.opacity(selected ? 0 : 0.4)) }
    }
    .buttonStyle(.plain)
    .disabled(next == nil)
    .accessibilityLabel(Self.unitName(unit))
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("unit-\(unit.rawValue)")
  }

  static func unitName(_ unit: QuantityUnit) -> String {
    switch unit {
    case .g: "grammes"
    case .kg: "kilos"
    case .l: "litres"
    }
  }

  private func save() {
    guard let edit = ItemEdit(label: label, quantityText: quantityText) else { return }
    if edit.label != target.label || edit.quantity != target.quantity { onSave(edit) }
    dismiss()
  }
}

extension View {
  /// Champ du panneau de l'article : papier, filet, 44 pt au moins.
  fileprivate func sheetField() -> some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return
      self
      .textFieldStyle(.plain)
      .font(.system(.body, design: .monospaced))
      .foregroundStyle(Palette.ink)
      .padding(.horizontal, 12)
      .frame(minHeight: 44)
      .background(Palette.paper, in: shape)
      .overlay { shape.strokeBorder(Palette.paperEdge, lineWidth: 1) }
  }
}
