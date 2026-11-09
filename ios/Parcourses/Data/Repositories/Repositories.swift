import Foundation

/// Erreurs d'écriture des repositories.
enum RepositoryError: Error, Equatable {
  case notFound(UUID)
  /// Une liste supprimée, en attente d'envoi, n'accepte plus aucune écriture.
  case listDeleted(UUID)
  /// Une coche ne s'ajoute pas à une visite déjà close.
  case visitClosed(UUID)
  /// Un article déjà coché ne l'est pas une seconde fois (double appui, Live Activity et écran au même instant).
  case alreadyChecked(UUID)
}

extension RepositoryError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notFound: "Cet élément n'existe plus."
    case .listDeleted: "Cette liste a été supprimée."
    case .visitClosed: "Cette visite est déjà terminée."
    case .alreadyChecked: "Cet article est déjà coché."
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
  /// `organicAisle` à `nil` : inconnu ici, la valeur en cache est conservée.
  func upsertStore(
    id: UUID, name: String, chain: String?, address: String?, lastDistanceM: Double?, organicAisle: Bool?
  ) throws
  /// Valeur du serveur, plus fraîche que le cache. Sans effet si le magasin n'est pas en cache.
  func updateOrganicAisle(id: UUID, organicAisle: Bool) throws
  func markUsed(id: UUID, at date: Date) throws
}

/// Visites et coches.
protocol VisitRepository {
  func visit(id: UUID) throws -> Visit?
  /// Visite ouverte, unique : voir `startVisit`. Sert à la reprise au lancement.
  func openVisit() throws -> Visit?
  /// Une seule visite reste ouverte. Même liste et même magasin, et une activité il y a moins de `staleAfter` :
  /// la visite existante est renvoyée. Sinon toute visite ouverte est d'abord abandonnée (voir `abandonVisit` :
  /// close **à sa dernière coche**, jamais à `date`, qui allongerait la visite de tout le temps passé ailleurs),
  /// puis une visite neuve est créée. Une visite neuve commence sans introuvable : ceux de `listId` reviennent à
  /// acheter.
  @discardableResult
  func startVisit(
    storeId: UUID, listId: UUID, listWasSorted: Bool, at date: Date, staleAfter: TimeInterval
  ) throws -> Visit
  /// Dernière activité d'une visite : sa dernière coche, sinon son début. `nil` si elle n'existe pas.
  func lastActivity(visitId: UUID) throws -> Date?
  /// `sendAfter` : durée pendant laquelle la coche reste annulable sans jamais partir au serveur.
  @discardableResult
  func addCheck(
    visitId: UUID, itemId: UUID, subject: CheckSubject, checkedAt: Date, sendAfter: TimeInterval
  ) throws -> Check
  /// Retire une coche pas encore partie, et renvoie `false` sans rien changer si elle a déjà été envoyée.
  @discardableResult func removeCheck(id: UUID) throws -> Bool
  /// Coche l'article et ajoute la coche dans une seule sauvegarde : l'un ne va pas sans l'autre. Un article déjà
  /// coché est refusé (`RepositoryError.alreadyChecked`) : un double événement ne compte pas deux passages devant
  /// le même rayon.
  @discardableResult
  func checkItem(
    visitId: UUID, itemId: UUID, subject: CheckSubject, checkedAt: Date, sendAfter: TimeInterval
  ) throws -> Check
  /// Décoche l'article et retire la coche si elle n'est pas partie, dans une seule sauvegarde.
  func uncheckItem(itemId: UUID, checkId: UUID?, at date: Date) throws
  /// Coches d'une visite, dans l'ordre chronologique.
  func checks(visitId: UUID) throws -> [Check]
  /// Clôt la visite, sans effet si elle l'est déjà. Sans aucune coche et jamais reçue par le serveur, elle est
  /// supprimée (#9 §5.5) : renvoie alors `false`. Reçue puis vidée de ses coches, elle est close à son début et la
  /// clôture part, sinon elle resterait ouverte chez lui (#62).
  @discardableResult func closeVisit(id: UUID, at date: Date) throws -> Bool
  /// Clôt une visite quittée sans « Terminer » (restée ouverte trop longtemps, liste disparue) : à sa dernière
  /// coche, ou supprimée si elle n'en a aucune et n'est jamais partie (sinon close à son début, comme `closeVisit`,
  /// #62). Personne n'a répondu à « garder ou retirer » : la réponse par défaut, garder, s'applique, et les articles
  /// introuvables (non cochés) de sa liste reviennent à acheter (#54, M3).
  ///
  /// Sans effet, et sans erreur, si la visite n'existe plus, si elle est déjà close, ou si sa dernière activité
  /// date de moins de `staleAfter` avant `date`. Renvoie `true` si cet appel l'a close ou supprimée.
  @discardableResult func abandonVisit(id: UUID, at date: Date, staleAfter: TimeInterval) throws -> Bool
}

extension VisitRepository {
  @discardableResult
  func addCheck(visitId: UUID, itemId: UUID, subject: CheckSubject, checkedAt: Date) throws -> Check {
    try addCheck(visitId: visitId, itemId: itemId, subject: subject, checkedAt: checkedAt, sendAfter: 0)
  }

  /// Sans péremption : la visite ouverte de cette liste et de ce magasin est toujours reprise.
  @discardableResult
  func startVisit(storeId: UUID, listId: UUID, listWasSorted: Bool, at date: Date) throws -> Visit {
    try startVisit(storeId: storeId, listId: listId, listWasSorted: listWasSorted, at: date, staleAfter: .infinity)
  }
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
