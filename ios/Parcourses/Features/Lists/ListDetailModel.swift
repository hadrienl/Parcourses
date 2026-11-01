import Domain
import Foundation
import Observation

/// Un article tel qu'affiché : une valeur, jamais l'objet SwiftData, pour survivre à sa suppression.
struct ItemRow: Identifiable, Equatable {
  let id: UUID
  let label: String
  let quantity: String?
  let categoryId: String
  let normalizedName: String
  let isChecked: Bool

  /// « Tomates, 2 », suivi par VoiceOver de `accessibilityState` (#9 §11).
  var accessibilityLabel: String {
    [label, quantity].compactMap(\.self).joined(separator: ", ")
  }

  var accessibilityState: String {
    isChecked ? "coché" : "non coché"
  }
}

/// Articles d'un même rayon.
struct ItemSection: Identifiable, Equatable {
  let categoryId: String
  let title: String
  let items: [ItemRow]

  var id: String { categoryId }
}

/// Modèle de l'écran Liste.
@Observable
final class ListDetailModel {
  private(set) var name = ""
  private(set) var sections: [ItemSection] = []
  private(set) var isEmpty = true
  /// Faux jusqu'au premier `load()` : évite d'afficher « Liste vide » avant la lecture.
  private(set) var isLoaded = false
  /// Liste inconnue ou supprimée.
  private(set) var isMissing = false
  var input = ""
  var errorMessage: String?

  private let listId: UUID
  private let lists: any ListRepository
  private let products: any ProductRepository
  private let analyzer: EntryAnalyzer
  private let now: () -> Date
  private let categoryRepository: any CategoryRepository
  private var categories: [(id: String, label: String)] = []
  private var index = ItemSuggestionIndex(history: [], products: [], normalizeFallback: { $0 })
  private var pendingNames: Set<String> = []

  init(
    listId: UUID, lists: any ListRepository, products: any ProductRepository, categories: any CategoryRepository,
    analyzer: EntryAnalyzer, now: @escaping () -> Date = { .now }
  ) {
    self.listId = listId
    self.lists = lists
    self.products = products
    self.analyzer = analyzer
    self.now = now
    categoryRepository = categories
  }

  /// Propositions pour la saisie en cours, quantité ignorée (« 2 lai » cherche « lai »).
  var suggestions: [ItemSuggestion] {
    index.suggestions(forms: analyzer.searchForms(analyzer.analyze(input).label), excluding: pendingNames)
  }

  /// Lecture complète, appelée par la vue : l'initialisation ne fait aucune E/S.
  func load() {
    perform {
      categories = try categoryRepository.categories().map { ($0.id, $0.label) }
      let list = try lists.list(id: listId)
      name = list?.name ?? ""
      isMissing = list == nil
    }
    reloadItems()
    rebuildIndex()
    isLoaded = true
  }

  /// Articles affichés. Ne relit pas l'historique : une coche ne change pas les propositions possibles.
  private func reloadItems() {
    perform {
      let rows = try lists.items(listId: listId).map {
        ItemRow(
          id: $0.id, label: $0.label, quantity: $0.quantity, categoryId: $0.categoryId,
          normalizedName: $0.normalizedName, isChecked: $0.checkedAt != nil)
      }
      isEmpty = rows.isEmpty
      sections = Self.group(rows, categories: categories)
      pendingNames = Set(rows.filter { !$0.isChecked }.map(\.normalizedName))
    }
  }

  /// Index d'autocomplétion, à refaire seulement quand l'ensemble des articles change.
  private func rebuildIndex() {
    perform {
      index = ItemSuggestionIndex(
        history: try lists.itemHistory(), products: try products.products(),
        normalizeFallback: { [analyzer] in analyzer.analyze($0).normalizedName })
    }
  }

  /// Ajoute la saisie en cours. Sans effet si elle est vide. La saisie n'est effacée qu'en cas de succès.
  func submit() {
    let entry = analyzer.analyze(input)
    guard !entry.label.isEmpty else { return }
    add(
      label: entry.label, normalizedName: entry.normalizedName, quantity: entry.quantity, productId: nil,
      categoryId: entry.categoryId)
  }

  /// Ajoute une proposition en gardant la quantité déjà tapée.
  func add(_ suggestion: ItemSuggestion) {
    let entry = analyzer.analyze(input)
    let categoryId = suggestion.categoryId ?? analyzer.analyze(suggestion.label).categoryId
    add(
      label: suggestion.label, normalizedName: suggestion.normalizedName, quantity: entry.quantity,
      productId: suggestion.productId, categoryId: categoryId)
  }

  func toggle(_ row: ItemRow) {
    let date = now()
    perform { try lists.setChecked(itemId: row.id, checkedAt: row.isChecked ? nil : date, at: date) }
    reloadItems()
  }

  func delete(_ row: ItemRow) {
    perform { try lists.deleteItem(id: row.id) }
    reloadItems()
    rebuildIndex()
  }

  /// Regroupe par rayon, dans l'ordre générique (`rank`). Un identifiant inconnu rejoint `other`.
  static func group(_ rows: [ItemRow], categories: [(id: String, label: String)]) -> [ItemSection] {
    let known = Set(categories.map(\.id))
    let other = CategoryClassifier.otherCategoryId
    let byCategory = Dictionary(grouping: rows) { known.contains($0.categoryId) ? $0.categoryId : other }
    var ordered = categories
    if !known.contains(other) { ordered.append((other, "Autres")) }
    return ordered.compactMap { category in
      byCategory[category.id].map { ItemSection(categoryId: category.id, title: category.label, items: $0) }
    }
  }

  private func add(label: String, normalizedName: String, quantity: String?, productId: UUID?, categoryId: String) {
    let succeeded = perform {
      try lists.addItem(
        listId: listId, label: label, normalizedName: normalizedName, quantity: quantity, productId: productId,
        categoryId: categoryId, at: now())
    }
    if succeeded { input = "" }
    reloadItems()
    rebuildIndex()
  }

  @discardableResult private func perform(_ work: () throws -> Void) -> Bool {
    do {
      try work()
      return true
    } catch {
      errorMessage = "L'opération a échoué : \(error.localizedDescription)"
      return false
    }
  }
}
