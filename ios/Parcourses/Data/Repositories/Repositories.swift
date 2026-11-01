import Foundation

/// Erreurs d'écriture des repositories.
enum RepositoryError: Error, Equatable {
  case notFound(UUID)
  /// Une liste supprimée, en attente d'envoi, n'accepte plus aucune écriture.
  case listDeleted(UUID)
  /// Une coche ne s'ajoute pas à une visite déjà close.
  case visitClosed(UUID)
}

extension RepositoryError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notFound: "Cet élément n'existe plus."
    case .listDeleted: "Cette liste a été supprimée."
    case .visitClosed: "Cette visite est déjà terminée."
    }
  }
}

/// Ce qu'une coche désigne : produit du catalogue ou catégorie (`productId` xor `categoryId`, #8 §2.6).
enum CheckSubject: Equatable, Sendable {
  case product(UUID)
  case category(String)
}

/// Listes et articles.
protocol ListRepository {
  /// Listes non supprimées, la plus récemment modifiée d'abord.
  func lists() throws -> [ShoppingList]
  func list(id: UUID) throws -> ShoppingList?
  @discardableResult func createList(name: String, at date: Date) throws -> ShoppingList
  func renameList(id: UUID, name: String, at date: Date) throws
  /// Suppression douce : la liste disparaît de `lists()` et reste en base jusqu'à l'envoi (9.7).
  func deleteList(id: UUID, at date: Date) throws

  /// Articles d'une liste, triés par `position`. Vide si la liste est supprimée.
  func items(listId: UUID) throws -> [ListItem]
  @discardableResult
  func addItem(
    listId: UUID, label: String, normalizedName: String, quantity: String?, productId: UUID?, categoryId: String,
    at date: Date
  ) throws -> ListItem
  func setChecked(itemId: UUID, checkedAt: Date?, at date: Date) throws
  func setNotFound(itemId: UUID, notFoundAt: Date?, at date: Date) throws
  func deleteItem(id: UUID) throws
  /// Articles de toutes les listes non supprimées, source de l'autocomplétion.
  func itemHistory() throws -> [ListItem]
}

/// Cache local du catalogue de produits, vide tant que la descente (9.7) ne l'a pas rempli.
protocol ProductRepository {
  func products() throws -> [Product]
}

/// Cache local des magasins.
protocol StoreRepository {
  func store(id: UUID) throws -> Store?
  /// Magasins déjà utilisés, du plus récent au plus ancien.
  func recentStores(limit: Int) throws -> [Store]
  /// `lastDistanceM` : l'app passe toujours `nil`, aucune distance à l'utilisateur n'est conservée.
  func upsertStore(id: UUID, name: String, chain: String?, address: String?, lastDistanceM: Double?) throws
  func markUsed(id: UUID, at date: Date) throws
}

/// Visites et coches.
protocol VisitRepository {
  func visit(id: UUID) throws -> Visit?
  /// Visite non close la plus récente, pour la reprise au lancement.
  func openVisit() throws -> Visit?
  @discardableResult
  func startVisit(storeId: UUID, listId: UUID, listWasSorted: Bool, at date: Date) throws -> Visit
  @discardableResult
  func addCheck(visitId: UUID, itemId: UUID, subject: CheckSubject, checkedAt: Date) throws -> Check
  /// Coches d'une visite, dans l'ordre chronologique.
  func checks(visitId: UUID) throws -> [Check]
  /// Clôt la visite, sans effet si elle l'est déjà. Sans aucune coche, elle est supprimée et jamais envoyée (#9 §5.5) : renvoie alors `false`.
  @discardableResult func closeVisit(id: UUID, at date: Date) throws -> Bool
}

/// Instantanés du graphe. Le contenu vient toujours du serveur.
protocol GraphRepository {
  func snapshot(storeId: UUID) throws -> GraphSnapshot?
  /// Remplace l'instantané du magasin et ne garde que les plus récents (LRU sur `fetchedAt`).
  func saveSnapshot(
    storeId: UUID, snapshotVersion: Int64, paramsVersion: Int64, confidenceQ: Int64, payload: Data, at date: Date
  ) throws
}

/// Catégories de rayon.
protocol CategoryRepository {
  /// Catégories triées par `(rank, id)`.
  func categories() throws -> [Category]
  /// Aligne la table sur `CategoryResources` si la version du fichier dépasse celle déjà appliquée.
  func seedIfNeeded() throws
  /// Renseigne `remoteId` par slug. `shared/categories/` fait foi : aucune catégorie locale n'est ajoutée ni
  /// supprimée, et une catégorie que le serveur ne connaît pas repasse à `nil`.
  func applyRemoteIds(_ rows: [CategoryRow]) throws
}
