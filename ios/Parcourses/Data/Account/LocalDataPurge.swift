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

  /// Étape en échec (#129) : elle donne le code public de « Nous écrire ». L'erreur d'origine n'est journalisée qu'en
  /// privé. Un arrêt simulé par `checkpoint` n'est jamais enveloppé : la suppression du compte le reconnaît.
  nonisolated struct Failure: Error {
    let step: Step
    let underlying: any Error
  }

  private let container: ModelContainer
  private let keychain: any SecureStore
  private let defaults: UserDefaults
  private let urlCache: URLCache
  private let seedSource: @MainActor () throws -> CategorySeed
  private let injectedFailure: @MainActor (Step) throws -> Void

  /// `injectedFailure` : tests UI, lève avant le travail d'une étape comme le ferait un stockage plein (#129).
  init(
    container: ModelContainer, keychain: any SecureStore = KeychainStore(), defaults: UserDefaults = .standard,
    urlCache: URLCache = .shared, seedSource: @escaping @MainActor () throws -> CategorySeed = CategorySeed.bundled,
    injectedFailure: @escaping @MainActor (Step) throws -> Void = { _ in }
  ) {
    self.container = container
    self.keychain = keychain
    self.defaults = defaults
    self.urlCache = urlCache
    self.seedSource = seedSource
    self.injectedFailure = injectedFailure
  }

  /// `checkpoint` lève pour simuler un arrêt après une étape (tests) : rien de ce qui suit n'est fait.
  /// `keepingSession` : passage d'un compte e-mail à un autre (#87), la session du nouveau compte reste dans le
  /// Keychain ; l'appelant y acquitte ensuite ce compte (`acknowledgeAccount`). Une étape en échec lève `Failure`.
  func run(keepingSession: Bool = false, checkpoint: (Step) throws -> Void = { _ in }) throws {
    let context = container.mainContext
    // Base : tout ou rien, en une seule sauvegarde. `OutboxEntry` emporte ses charges utiles.
    try perform(.storePurged) {
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
    }
    try checkpoint(.storePurged)

    // Sans catégories, aucun article ne pourrait être classé : le référentiel embarqué revient tout de suite.
    try perform(.categoriesSeeded) {
      try SwiftDataCategoryRepository(context: context, seedSource: seedSource).seedIfNeeded()
    }
    try checkpoint(.categoriesSeeded)

    // Session, dernier compte connu (`last-account-id`) et sentinelle : le nouveau compte est adopté sans reprise.
    try perform(.keychainPurged) {
      if !keepingSession { try keychain.removeAll() }
    }
    try checkpoint(.keychainPurged)

    try perform(.preferencesPurged) {
      UserDefaultsSyncCursors(defaults: defaults).removeAll()
      // Le nouveau compte naît anonyme : une session absente pourra en recréer un.
      UserDefaultsAccountKindStore(defaults: defaults).clear()
      UserDefaultsActivityDismissals.forget(in: defaults)
      urlCache.removeAllCachedResponses()
    }
    try checkpoint(.preferencesPurged)
  }

  /// Le travail d'une étape ; son échec, injecté ou réel, devient `Failure` avec l'étape.
  private func perform(_ step: Step, _ work: () throws -> Void) throws {
    do {
      try injectedFailure(step)
      try work()
    } catch {
      throw Failure(step: step, underlying: error)
    }
  }
}
