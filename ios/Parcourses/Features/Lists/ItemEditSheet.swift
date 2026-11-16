import Domain
import SwiftUI

/// Article ouvert dans le panneau (#110) : appui long sur une ligne de la liste, ou « Quantité » du mode courses.
struct ItemEditTarget: Identifiable, Equatable {
  let id: UUID
  let label: String
  let quantity: String?
}

/// Ce que le panneau enregistre, par rapport à l'article tel qu'il était à l'ouverture : seuls les champs changés par
/// la personne partent, pour ne pas annuler une modification arrivée d'un autre membre pendant que le panneau était
/// ouvert.
struct ItemEdit: Equatable {
  /// Nouveau libellé, sans blancs de bord et coupé à 200 points de code ; `nil` s'il n'a pas changé.
  let label: String?
  /// Vrai si la quantité a changé ; `quantity` est alors la nouvelle (`nil` : effacée).
  let changesQuantity: Bool
  let quantity: String?

  /// `nil` si le libellé est vide. Chaque suite de retours à la ligne (collés) devient une espace : le libellé tient sur
  /// une ligne, même règle qu'Android.
  init?(target: ItemEditTarget, label: String, quantityText: String) {
    let trimmed = Self.singleLine(label).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let cut = Self.cut(trimmed)
    self.label = cut == target.label ? nil : cut
    quantity = ItemQuantity.quantityInput(quantityText)
    changesQuantity = quantity != target.quantity
  }

  /// Rien à écrire.
  var isEmpty: Bool { label == nil && !changesQuantity }

  /// `list_items.label` : 200 caractères au plus (`char_length`, en points de code).
  static let maxLabelLength = 200

  /// Chaque suite de retours à la ligne (`\n`, `\r`, `\r\n`, VT, FF, U+0085, U+2028, U+2029) devient une espace.
  static func singleLine(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
  }

  /// Saisie dans le libellé, champ multi-ligne pour l'affichage seulement. `submit` : « Terminé » a inséré un retour à
  /// la ligne (au curseur, ou en fin de texte avec une correction automatique) ; il est retiré et le clavier doit se
  /// fermer. Un texte collé voit chaque suite de retours devenir une espace. Au-delà de 200 points de code, la
  /// modification est refusée, comme sur Android : rien n'est coupé en silence.
  static func labelInput(old: String, new: String) -> (text: String, submit: Bool) {
    guard new != old else { return (new, false) }
    if !old.contains(where: \.isNewline) {
      let withoutNewlines = new.filter { !$0.isNewline }
      let insertedOne = new.count - withoutNewlines.count == 1
      if insertedOne && (withoutNewlines == old || new.last?.isNewline == true) {
        return (limited(old: old, new: withoutNewlines, max: maxLabelLength), true)
      }
    }
    return (limited(old: old, new: singleLine(new), max: maxLabelLength), false)
  }

  /// Limite de saisie en points de code (`char_length`), même règle qu'Android (`MaxCodePoints`) : seule une
  /// modification qui fait grandir le texte au-delà de `max` est refusée ; un texte déjà trop long reste modifiable.
  static func limited(old: String, new: String, max: Int) -> String {
    let count = new.unicodeScalars.count
    return count > max && count > old.unicodeScalars.count ? old : new
  }

  /// Coupé à `maxLabelLength` points de code.
  static func cut(_ text: String) -> String {
    var cut = ""
    cut.unicodeScalars.append(contentsOf: text.unicodeScalars.prefix(maxLabelLength))
    return cut
  }
}

extension ListRepository {
  /// Enregistre le panneau sur l'article **actuel** : un libellé changé est reclassé comme à l'ajout (forme normalisée
  /// et rayon), sans en extraire de quantité ; un champ inchangé garde la valeur actuelle, même venue d'ailleurs.
  /// Même chemin pour l'écran Liste et le mode courses.
  func apply(_ edit: ItemEdit, to itemId: UUID, analyzer: EntryAnalyzer, at date: Date) throws {
    guard !edit.isEmpty else { return }
    guard let current = try item(id: itemId) else { throw RepositoryError.notFound(itemId) }
    let entry = edit.label.map { analyzer.analyze(label: $0) }
    try updateItem(
      itemId: itemId, label: entry?.label ?? current.label,
      normalizedName: entry?.normalizedName ?? current.normalizedName,
      categoryId: entry?.categoryId ?? current.categoryId,
      quantity: edit.changesQuantity ? edit.quantity : current.quantity, at: date)
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
  /// Mi-hauteur, sauf aux tailles de texte d'accessibilité : le panneau s'ouvre alors en grand.
  @State private var detent: PresentationDetent
  @FocusState private var labelFocused: Bool

  init(target: ItemEditTarget, largeText: Bool = false, onSave: @escaping (ItemEdit) -> Void) {
    self.target = target
    self.onSave = onSave
    _label = State(initialValue: target.label)
    _quantityText = State(initialValue: target.quantity ?? "")
    _detent = State(initialValue: largeText ? .large : .medium)
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
        // Pictogrammes, comme les autres feuilles : la barre plafonne la taille de ses textes, l'appui long montre la
        // visionneuse de grand contenu.
        ToolbarItem(placement: .cancellationAction) {
          Button("Annuler", systemImage: "xmark") { dismiss() }
            .accessibilityIdentifier("cancelItem")
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Enregistrer", systemImage: "checkmark", action: save)
            .disabled(ItemEdit(target: target, label: label, quantityText: quantityText) == nil)
            .accessibilityIdentifier("saveItem")
        }
      }
    }
    .presentationDetents([.medium, .large], selection: $detent)
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    // Fond opaque : le verre de la feuille laisse transparaître la liste et dégrade le contraste.
    .presentationBackground(Palette.paper)
    .accessibilityIdentifier("itemSheet")
  }

  private var labelSection: some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      sectionTitle("Libellé")
      // Sur plusieurs lignes : un long libellé reste lisible en entier aux grandes tailles de texte.
      TextField("Libellé", text: $label, axis: .vertical)
        .lineLimit(1...4)
        .sheetField()
        .submitLabel(.done)
        .focused($labelFocused)
        .onChange(of: label) { old, value in
          let input = ItemEdit.labelInput(old: old, new: value)
          if input.submit { labelFocused = false }
          if input.text != value { label = input.text }
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
          // Place réservée à la croix d'effacement, des deux côtés : le texte reste centré et ne passe pas dessous.
          .padding(.horizontal, quantity == nil ? 0 : 28)
          .sheetField()
          .multilineTextAlignment(.center)
          .submitLabel(.done)
          .onChange(of: quantityText) { old, value in
            let limited = ItemEdit.limited(old: old, new: value, max: ItemQuantity.maxLength)
            if limited != value { quantityText = limited }
          }
          .accessibilityIdentifier("quantityField")
          .overlay(alignment: .trailing) { clearButton }
        stepButton(delta: 1, systemImage: "plus", label: "Augmenter la quantité", identifier: "quantityIncrement")
      }
      HStack(spacing: Space.s) {
        ForEach(QuantityUnit.allCases, id: \.self) { unit in unitChip(unit) }
      }
    }
  }

  /// « Effacer la quantité » : la croix d'effacement d'iOS, dans le champ, tant qu'il y a une quantité. Un pictogramme
  /// lu par VoiceOver, sans texte affiché que la feuille à mi-hauteur pourrait rogner.
  @ViewBuilder private var clearButton: some View {
    if quantity != nil {
      Button {
        quantityText = ""
      } label: {
        // Taille plafonnée, comme la croix système des champs : elle tient dans sa place réservée en AX5.
        Image(systemName: "xmark.circle.fill")
          .font(.body)
          .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          .foregroundStyle(Palette.inkMuted)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Effacer la quantité")
      .accessibilityIdentifier("clearQuantity")
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(TicketFont.aisle)
      .tracking(TicketFont.aisleTracking)
      .textCase(.uppercase)
      .foregroundStyle(Palette.inkMuted)
      .fixedSize(horizontal: false, vertical: true)
      // Lu tel quel (pas les capitales, épelées sinon), comme un en-tête.
      .accessibilityLabel(Text(title))
      .accessibilityAddTraits(.isHeader)
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
        .padding(.horizontal, Space.m)
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
    guard let edit = ItemEdit(target: target, label: label, quantityText: quantityText) else { return }
    if !edit.isEmpty { onSave(edit) }
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
