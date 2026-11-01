import Foundation

/// Proposition d'autocomplétion.
struct ItemSuggestion: Identifiable, Equatable {
  /// Forme normalisée : deux saisies de même forme ne font qu'une proposition.
  let normalizedName: String
  let label: String
  let productId: UUID?
  let categoryId: String?
  let useCount: Int
  let lastUsedAt: Date?

  var id: String { normalizedName }
}

/// Index d'autocomplétion : historique de l'utilisateur et catalogue local.
///
/// Calcul pur, en mémoire : recherché à chaque frappe sans toucher au store.
struct ItemSuggestionIndex {
  private let entries: [ItemSuggestion]

  init(history: [ListItem], products: [Product], normalizeFallback: (String) -> String) {
    var byName: [String: ItemSuggestion] = [:]
    for product in products {
      let key = product.normalizedName.isEmpty ? normalizeFallback(product.name) : product.normalizedName
      guard !key.isEmpty else { continue }
      byName[key] = ItemSuggestion(
        normalizedName: key, label: product.name, productId: product.id, categoryId: product.categoryId, useCount: 0,
        lastUsedAt: nil)
    }
    // Du plus ancien au plus récent : le dernier libellé saisi l'emporte.
    for item in history.sorted(by: { $0.updatedAt < $1.updatedAt }) {
      let key = item.normalizedName.isEmpty ? normalizeFallback(item.label) : item.normalizedName
      guard !key.isEmpty else { continue }
      let known = byName[key]
      byName[key] = ItemSuggestion(
        normalizedName: key, label: item.label, productId: item.productId ?? known?.productId,
        categoryId: item.categoryId, useCount: (known?.useCount ?? 0) + 1, lastUsedAt: item.updatedAt)
    }
    entries = byName.values.sorted(by: Self.isRankedBefore)
  }

  /// Propositions dont un mot commence par l'une des formes, hors articles déjà à acheter.
  func suggestions(forms: [String], excluding excluded: Set<String>, limit: Int = 5) -> [ItemSuggestion] {
    guard !forms.isEmpty else { return [] }
    return Array(
      entries.lazy
        .filter { entry in
          !excluded.contains(entry.normalizedName)
            && forms.contains { entry.normalizedName.hasPrefix($0) || entry.normalizedName.contains(" \($0)") }
        }
        .prefix(limit))
  }

  /// Le plus utilisé, puis le plus récent, puis ordre stable sur les octets (déterministe).
  private static func isRankedBefore(_ a: ItemSuggestion, _ b: ItemSuggestion) -> Bool {
    if a.useCount != b.useCount { return a.useCount > b.useCount }
    if a.lastUsedAt != b.lastUsedAt { return (a.lastUsedAt ?? .distantPast) > (b.lastUsedAt ?? .distantPast) }
    return Array(a.normalizedName.utf8).lexicographicallyPrecedes(Array(b.normalizedName.utf8))
  }
}
