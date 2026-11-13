import Foundation
import SwiftData

/// Efface de l'appareil tout ce qui se rapporte au compte supprimé (#68 §5.4). Rejouable : chaque étape vide
/// ce qui reste, et une purge interrompue recommence au lancement suivant tant que le drapeau existe.
///
/// Ce qui reste : `auth.installed` (sinon le Keychain serait vidé une seconde fois, sans effet) et le référentiel
/// des catégories, amorcé à nouveau depuis le fichier embarqué.
struct LocalDataPurge {
  /// Points de passage, dans l'ordre. Les tests y simulent un arrêt du processus.
  nonisolated enum Step: CaseIterable, Sendable {
    case storePurged
    case categoriesSeeded
    case keychainPurged
    case preferencesPurged
  }

  private let container: ModelContainer
  private let keychain: any SecureStore
  private let defaults: UserDefaults
  private let urlCache: URLCache
  private let seedSource: @MainActor () throws -> CategorySeed

  init(
    container: ModelContainer, keychain: any SecureStore = KeychainStore(), defaults: UserDefaults = .standard,
    urlCache: URLCache = .shared, seedSource: @escaping @MainActor () throws -> CategorySeed = CategorySeed.bundled
  ) {
    self.container = container
    self.keychain = keychain
    self.defaults = defaults
    self.urlCache = urlCache
    self.seedSource = seedSource
  }

  /// `checkpoint` lève pour simuler un arrêt après une étape (tests) : rien de ce qui suit n'est fait.
  func run(checkpoint: (Step) throws -> Void = { _ in }) throws {
    let context = container.mainContext
    // Base : tout ou rien, en une seule sauvegarde. `OutboxEntry` emporte ses charges utiles.
    do {
      try context.delete(model: OutboxEntry.self)
      try context.delete(model: Check.self)
      try context.delete(model: Visit.self)
      try context.delete(model: ListItem.self)
      try context.delete(model: ShoppingList.self)
      // Magasins récents et instantanés : ils disent où la personne fait ses courses.
      try context.delete(model: Store.self)
      try context.delete(model: GraphSnapshot.self)
      // Catalogue en cache, téléchargé à nouveau par le nouveau compte.
      try context.delete(model: Product.self)
      try context.delete(model: Category.self)
      try context.delete(model: CategorySeedState.self)
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
    try checkpoint(.storePurged)

    // Sans catégories, aucun article ne pourrait être classé : le référentiel embarqué revient tout de suite.
    try SwiftDataCategoryRepository(context: context, seedSource: seedSource).seedIfNeeded()
    try checkpoint(.categoriesSeeded)

    // Session, dernier compte connu (`last-account-id`) et sentinelle : le nouveau compte est adopté sans reprise.
    try keychain.removeAll()
    try checkpoint(.keychainPurged)

    UserDefaultsSyncCursors(defaults: defaults).removeAll()
    UserDefaultsActivityDismissals.forget(in: defaults)
    urlCache.removeAllCachedResponses()
    try checkpoint(.preferencesPurged)
  }
}
