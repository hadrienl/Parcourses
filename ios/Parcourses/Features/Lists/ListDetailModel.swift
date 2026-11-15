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
  /// Initiale de l'auteur de la dernière modification, s'il est un autre membre (vecteur `008`).
  var authorMark: String?
  /// Son prénom, lu par VoiceOver.
  var authorName: String?

  /// « Tomates, 2 », suivi par VoiceOver de `accessibilityState` (#9 §11), et de l'auteur sur une liste partagée.
  var accessibilityLabel: String {
    let author = authorName.map { "dernière modification par \($0)" }
    return [label, quantity, author].compactMap(\.self).joined(separator: ", ")
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
  /// Mon rôle et les participants (#87, lot 87.4).
  private(set) var access = ListAccess()
  /// Liste partagée avec moi, puis retirée de l'appareil par un autre (retrait, suppression par le propriétaire).
  private(set) var wasRemoved = false
  /// Liste quittée ici (« Quitter la liste ») : l'écran revient à Mes listes, sans message.
  private(set) var didLeave = false
  /// Dernière modification d'un autre membre : « Modifiée par Léa · il y a 2 min ».
  private(set) var lastChange: (name: String, date: Date)?
  var input = ""
  var errorMessage: String?

  private(set) var listId: UUID
  private var remapObserver: IdentifierRemapObserver?
  private let lists: any ListRepository
  private let products: any ProductRepository
  private let analyzer: EntryAnalyzer
  private let now: () -> Date
  private let categoryRepository: any CategoryRepository
  private var categories: [(id: String, label: String)] = []
  private var index = ItemSuggestionIndex(history: [], products: [], normalizeFallback: { $0 })
  private var pendingNames: Set<String> = []
  private let accountId: () -> UUID?
  /// Liste quittée volontairement ici (« Quitter la liste »).
  private let wasLeft: (UUID) -> Bool

  init(
    listId: UUID, lists: any ListRepository, products: any ProductRepository, categories: any CategoryRepository,
    analyzer: EntryAnalyzer, now: @escaping () -> Date = { .now }, accountId: @escaping () -> UUID? = { nil },
    wasLeft: @escaping (UUID) -> Bool = { _ in false }
  ) {
    self.accountId = accountId
    self.wasLeft = wasLeft
    self.listId = listId
    self.lists = lists
    self.products = products
    self.analyzer = analyzer
    self.now = now
    categoryRepository = categories
    // La vue garde ce modèle : il suit la liste, sans perdre la saisie en cours.
    remapObserver = IdentifierRemapObserver { [weak self] remap in
      guard let self else { return }
      self.listId = remap[self.listId]
      self.reloadItems()
    }
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
      // Une liste partagée avec moi qui disparaît a été retirée : la maquette l'annonce en plein écran. Quittée par moi,
      // l'écran revient simplement à Mes listes.
      if list == nil, isLoaded, access.role != .owner {
        if wasLeft(listId) { didLeave = true } else { wasRemoved = true }
      }
      name = list?.name ?? name
      isMissing = list == nil
      if let list { access = ListAccess(list: list, me: accountId()) }
    }
    reloadItems()
    rebuildIndex()
    isLoaded = true
  }

  /// Articles affichés. Ne relit pas l'historique : une coche ne change pas les propositions possibles.
  private func reloadItems() {
    perform {
      let items = try lists.items(listId: listId)
      let access = access
      let rows = items.map {
        ItemRow(
          id: $0.id, label: $0.label, quantity: $0.quantity, categoryId: $0.categoryId,
          normalizedName: $0.normalizedName, isChecked: $0.checkedAt != nil,
          authorMark: access.authorMark(updatedBy: $0.updatedBy), authorName: access.otherName($0.updatedBy))
      }
      // La plus récente modification, si elle vient d'un autre membre ; masquée si c'est la mienne.
      let latest = items.max { $0.updatedAt < $1.updatedAt }
      lastChange = latest.flatMap { item in access.otherName(item.updatedBy).map { ($0, item.updatedAt) } }
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
    // Lecteur : la liste ne se modifie pas ici (Q5).
    guard access.capabilities.canEditItems else { return }
    let date = now()
    perform { try lists.setChecked(itemId: row.id, checkedAt: row.isChecked ? nil : date, at: date) }
    reloadItems()
  }

  func delete(_ row: ItemRow) {
    guard access.capabilities.canEditItems else { return }
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
    guard access.capabilities.canEditItems else { return }
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
