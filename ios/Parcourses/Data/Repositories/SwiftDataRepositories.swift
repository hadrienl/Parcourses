import Domain
import Foundation
import SwiftData

extension ModelContext {
  /// Enregistre, ou annule toutes les modifications en attente en cas d'échec.
  func commit() throws {
    try commit(using: save)
  }

  /// Variante à sauvegarde injectée : un store SwiftData sain n'échoue pas à la demande.
  func commit(using save: () throws -> Void) throws {
    do {
      try save()
    } catch {
      rollback()
      throw error
    }
  }
}

final class SwiftDataListRepository: ListRepository {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func lists() throws -> [ShoppingList] {
    try context.fetch(
      FetchDescriptor<ShoppingList>(
        predicate: #Predicate { $0.deletedAt == nil },
        sortBy: [SortDescriptor(\.updatedAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]))
  }

  func list(id: UUID) throws -> ShoppingList? {
    try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id && $0.deletedAt == nil }))
      .first
  }

  func createList(name: String, at date: Date) throws -> ShoppingList {
    let list = ShoppingList(name: name, createdAt: date, updatedAt: date)
    context.insert(list)
    try context.commit()
    return list
  }

  func renameList(id: UUID, name: String, at date: Date) throws {
    let list = try requireActiveList(id)
    list.name = name
    list.updatedAt = date
    list.syncState = .pending
    try context.commit()
  }

  func deleteList(id: UUID, at date: Date) throws {
    let list = try requireActiveList(id)
    list.deletedAt = date
    list.updatedAt = date
    list.syncState = .pending
    try context.commit()
  }

  func items(listId: UUID) throws -> [ListItem] {
    guard try !isDeleted(listId) else { return [] }
    return try context.fetch(
      FetchDescriptor<ListItem>(predicate: #Predicate { $0.listId == listId }, sortBy: [SortDescriptor(\.position)]))
  }

  func addItem(
    listId: UUID, label: String, normalizedName: String, quantity: String?, productId: UUID?, categoryId: String,
    at date: Date
  ) throws -> ListItem {
    _ = try requireActiveList(listId)
    let position = (try items(listId: listId).last?.position ?? -1) + 1
    let item = ListItem(
      listId: listId, label: label, normalizedName: normalizedName, quantity: quantity, productId: productId,
      categoryId: categoryId, position: position, updatedAt: date)
    context.insert(item)
    try context.commit()
    return item
  }

  func setChecked(itemId: UUID, checkedAt: Date?, at date: Date) throws {
    let item = try requireWritableItem(itemId)
    item.checkedAt = checkedAt
    item.updatedAt = date
    item.syncState = .pending
    try context.commit()
  }

  func setNotFound(itemId: UUID, notFoundAt: Date?, at date: Date) throws {
    let item = try requireWritableItem(itemId)
    // Champ purement local (#9 question 4) : rien à renvoyer au serveur.
    item.notFoundAt = notFoundAt
    item.updatedAt = date
    try context.commit()
  }

  func deleteItem(id: UUID) throws {
    context.delete(try requireWritableItem(id))
    try context.commit()
  }

  func itemHistory() throws -> [ListItem] {
    let deleted = Set(
      try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.deletedAt != nil })).map(\.id))
    return try context.fetch(FetchDescriptor<ListItem>()).filter { !deleted.contains($0.listId) }
  }

  private func requireActiveList(_ id: UUID) throws -> ShoppingList {
    guard let list = try context.fetch(FetchDescriptor<ShoppingList>(predicate: #Predicate { $0.id == id })).first
    else { throw RepositoryError.notFound(id) }
    guard list.deletedAt == nil else { throw RepositoryError.listDeleted(id) }
    return list
  }

  private func isDeleted(_ listId: UUID) throws -> Bool {
    let descriptor = FetchDescriptor<ShoppingList>(
      predicate: #Predicate { $0.id == listId && $0.deletedAt != nil })
    return try context.fetchCount(descriptor) > 0
  }

  private func requireWritableItem(_ id: UUID) throws -> ListItem {
    guard let item = try context.fetch(FetchDescriptor<ListItem>(predicate: #Predicate { $0.id == id })).first else {
      throw RepositoryError.notFound(id)
    }
    guard try !isDeleted(item.listId) else { throw RepositoryError.listDeleted(item.listId) }
    return item
  }
}

final class SwiftDataProductRepository: ProductRepository {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func products() throws -> [Product] {
    try context.fetch(FetchDescriptor<Product>())
  }
}

final class SwiftDataStoreRepository: StoreRepository {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func store(id: UUID) throws -> Store? {
    try context.fetch(FetchDescriptor<Store>(predicate: #Predicate { $0.id == id })).first
  }

  func recentStores(limit: Int) throws -> [Store] {
    var descriptor = FetchDescriptor<Store>(
      predicate: #Predicate { $0.lastUsedAt != nil }, sortBy: [SortDescriptor(\.lastUsedAt, order: .reverse)])
    descriptor.fetchLimit = limit
    return try context.fetch(descriptor)
  }

  func upsertStore(id: UUID, name: String, chain: String?, address: String?, lastDistanceM: Double?) throws {
    if let store = try store(id: id) {
      store.name = name
      store.chain = chain
      store.address = address
      store.lastDistanceM = lastDistanceM
    } else {
      context.insert(Store(id: id, name: name, chain: chain, address: address, lastDistanceM: lastDistanceM))
    }
    try context.commit()
  }

  func markUsed(id: UUID, at date: Date) throws {
    guard let store = try store(id: id) else { throw RepositoryError.notFound(id) }
    store.lastUsedAt = date
    try context.commit()
  }
}

final class SwiftDataVisitRepository: VisitRepository {
  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func visit(id: UUID) throws -> Visit? {
    try context.fetch(FetchDescriptor<Visit>(predicate: #Predicate { $0.id == id })).first
  }

  func openVisit() throws -> Visit? {
    var descriptor = FetchDescriptor<Visit>(
      predicate: #Predicate { $0.endedAt == nil }, sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  func startVisit(storeId: UUID, listId: UUID, listWasSorted: Bool, at date: Date) throws -> Visit {
    let visit = Visit(storeId: storeId, listId: listId, listWasSorted: listWasSorted, startedAt: date)
    context.insert(visit)
    try context.commit()
    return visit
  }

  func addCheck(visitId: UUID, itemId: UUID, subject: CheckSubject, checkedAt: Date) throws -> Check {
    guard let visit = try visit(id: visitId) else { throw RepositoryError.notFound(visitId) }
    guard visit.endedAt == nil else { throw RepositoryError.visitClosed(visitId) }
    let check: Check
    switch subject {
    case .product(let productId):
      check = Check(visitId: visitId, itemId: itemId, productId: productId, categoryId: nil, checkedAt: checkedAt)
    case .category(let categoryId):
      check = Check(visitId: visitId, itemId: itemId, productId: nil, categoryId: categoryId, checkedAt: checkedAt)
    }
    context.insert(check)
    try context.commit()
    return check
  }

  func checks(visitId: UUID) throws -> [Check] {
    try context.fetch(
      FetchDescriptor<Check>(predicate: #Predicate { $0.visitId == visitId }, sortBy: [SortDescriptor(\.checkedAt)]))
  }

  func closeVisit(id: UUID, at date: Date) throws -> Bool {
    guard let visit = try visit(id: id) else { throw RepositoryError.notFound(id) }
    guard visit.endedAt == nil else { return true }
    guard try !checks(visitId: id).isEmpty else {
      context.delete(visit)
      try context.commit()
      return false
    }
    visit.endedAt = date
    visit.endSyncState = .pending
    try context.commit()
    return true
  }
}

final class SwiftDataGraphRepository: GraphRepository {
  /// Nombre de magasins dont on garde l'instantané (#9 §4.2).
  static let maxSnapshots = 5

  private let context: ModelContext

  init(context: ModelContext) {
    self.context = context
  }

  func snapshot(storeId: UUID) throws -> GraphSnapshot? {
    try context.fetch(FetchDescriptor<GraphSnapshot>(predicate: #Predicate { $0.storeId == storeId })).first
  }

  func saveSnapshot(
    storeId: UUID, snapshotVersion: Int64, paramsVersion: Int64, confidenceQ: Int64, payload: Data, at date: Date
  ) throws {
    if let existing = try snapshot(storeId: storeId) {
      existing.snapshotVersion = snapshotVersion
      existing.paramsVersion = paramsVersion
      existing.confidenceQ = confidenceQ
      existing.fetchedAt = date
      existing.payload = payload
    } else {
      context.insert(
        GraphSnapshot(
          storeId: storeId, snapshotVersion: snapshotVersion, paramsVersion: paramsVersion, confidenceQ: confidenceQ,
          fetchedAt: date, payload: payload))
    }
    // Le fetch inclut l'insertion ci-dessus : remplacement et éviction partent dans la même sauvegarde.
    let snapshots = try context.fetch(
      FetchDescriptor<GraphSnapshot>(sortBy: [SortDescriptor(\.fetchedAt, order: .reverse)]))
    for stale in snapshots.dropFirst(Self.maxSnapshots) {
      context.delete(stale)
    }
    try context.commit()
  }
}

/// Référentiel de catégories à appliquer au store.
struct CategorySeed {
  /// Identifiants renommés depuis les versions précédentes de `categories.json` (ancien → nouveau).
  /// À compléter en même temps que le fichier, avec une hausse de sa `version`.
  static let renamedIds: [String: String] = [:]

  let version: Int
  let categories: [ItemCategory]
  var renamedIds: [String: String] = CategorySeed.renamedIds

  /// Référentiel embarqué dans `Domain`.
  static func bundled() throws -> CategorySeed {
    CategorySeed(version: try CategoryResources.categoriesVersion(), categories: try CategoryResources.categories())
  }
}

final class SwiftDataCategoryRepository: CategoryRepository {
  private let context: ModelContext
  private let seedSource: @MainActor () throws -> CategorySeed

  init(context: ModelContext, seedSource: @escaping @MainActor () throws -> CategorySeed = CategorySeed.bundled) {
    self.context = context
    self.seedSource = seedSource
  }

  func categories() throws -> [Category] {
    try context.fetch(FetchDescriptor<Category>(sortBy: [SortDescriptor(\.rank), SortDescriptor(\.id)]))
  }

  func seedIfNeeded() throws {
    let seed = try seedSource()
    let state = try context.fetch(FetchDescriptor<CategorySeedState>()).first
    guard seed.version > (state?.version ?? 0) else { return }

    var existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Category>()).map { ($0.id, $0) })
    for category in seed.categories {
      if let row = existing.removeValue(forKey: category.id) {
        row.rank = category.rank
        row.label = category.labelFr
      } else {
        // Le fichier embarqué n'a pas de slug distinct : l'identifiant de Domain en tient lieu.
        context.insert(Category(id: category.id, slug: category.id, rank: category.rank, label: category.labelFr))
      }
    }
    // Ce qui reste n'est plus dans le fichier.
    existing.values.forEach(context.delete)
    try remapReferences(seed: seed)

    if let state {
      state.version = seed.version
    } else {
      context.insert(CategorySeedState(version: seed.version))
    }
    try context.commit()
  }

  /// Applique les renommages. Une référence vers un id disparu sans successeur passe en `other`,
  /// pour qu'aucun article ne pointe vers une catégorie absente.
  private func remapReferences(seed: CategorySeed) throws {
    let known = Set(seed.categories.map(\.id))
    func target(of id: String) -> String {
      let renamed = seed.renamedIds[id] ?? id
      return known.contains(renamed) ? renamed : CategoryClassifier.otherCategoryId
    }
    for item in try context.fetch(FetchDescriptor<ListItem>()) {
      item.categoryId = target(of: item.categoryId)
    }
    for product in try context.fetch(FetchDescriptor<Product>()) {
      if let id = product.categoryId { product.categoryId = target(of: id) }
    }
    for check in try context.fetch(FetchDescriptor<Check>()) {
      if let id = check.categoryId { check.categoryId = target(of: id) }
    }
  }
}
