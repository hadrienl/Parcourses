import Foundation

/// Erreur distante classée pour la file d'envoi (9.7, contrat hors ligne de `docs/data-model.md`).
nonisolated enum RemoteError: Error, Sendable, Equatable {
  /// Pas de réseau ou requête interrompue.
  case network
  /// Session absente ou expirée.
  case unauthorized
  /// Code `42501` uniquement : refus RLS ou privilège. Un 403 sans code n'en est pas un (`server`).
  case forbidden
  /// `23514` et `23505` : renvoyer la même ligne ne changerait rien.
  case constraint(code: String)
  /// `23503` : la ligne parente n'est pas encore arrivée. Réessai à plafonner (9.7).
  case dependencyMissing(code: String)
  /// Requête invalide, définitive.
  case rejected(code: String)
  /// Erreur côté serveur ou passerelle.
  case server(code: String)
  /// Réponse illisible, sans code ni statut exploitable. Réessayable : on ne sait pas si la ligne est passée.
  case unexpected
  /// La session appartient à un autre compte que le dernier connu : les lignes existantes ne sont plus
  /// visibles, et un enregistrement « réussirait » sans rien écrire. `SyncEngine` réidentifie alors les données.
  case accountChanged
  /// Catégorie absente de la table serveur, même après relecture. Jamais abandonnée : le serveur peut être en
  /// retard sur `shared/categories/`, et la coche ne doit pas être perdue.
  case unknownCategory(String)
  /// Keychain verrouillé (arrière-plan avant le premier déverrouillage) : la session existe peut-être encore.
  case keychainLocked
  /// Suppression du compte seulement : GoTrue répond que le compte ou sa session n'existent plus
  /// (`user_not_found`, `refresh_token_not_found`, `session_not_found`). Seule preuve d'une suppression faite.
  case accountGone(code: String)
  /// Suppression du compte seulement : la requête n'a pas quitté l'appareil (pas de réseau, hôte introuvable).
  case notSent

  /// PostgREST ne trouve pas la fonction appelée : serveur en retard d'une migration. Reste `rejected`, la file
  /// n'en dépend pas ; seule la résolution des produits la réessaie plus tôt (`SyncRetryPolicy.resolutionDelay`).
  static let functionNotFoundCode = "PGRST202"

  /// `true` si l'élément doit rester dans la file.
  var isRetryable: Bool {
    switch self {
    case .network, .unauthorized, .dependencyMissing, .server, .unexpected, .accountChanged, .unknownCategory,
      .keychainLocked, .accountGone, .notSent:
      true
    case .forbidden, .constraint, .rejected:
      false
    }
  }

  /// 4xx sans code : ni réessai sans fin, ni abandon immédiat. 403, 408 et 429 restent passagers.
  var isCappedClientFailure: Bool {
    guard case .server(let code) = self, let status = Int(code) else { return false }
    return (400..<500).contains(status) && ![403, 408, 429].contains(status)
  }

  /// Classe un code renvoyé par PostgREST (SQLSTATE ou `PGRSTxxx`).
  static func fromPostgrest(code: String?) -> RemoteError {
    guard let code else { return .unexpected }
    if code == "42501" { return .forbidden }
    if code == "23514" || code == "23505" { return .constraint(code: code) }
    if code == "23503" { return .dependencyMissing(code: code) }
    if ["PGRST301", "PGRST302", "PGRST303"].contains(code) { return .unauthorized }
    // PGRST0xx : base injoignable ou saturée, et PGRST5xx : erreur interne.
    if code.hasPrefix("PGRST0") || code.hasPrefix("PGRST5") { return .server(code: code) }
    // Autres PGRST : requête mal formée ; 22, 23, 42, P0 : données ou SQL refusés.
    if ["PGRST", "22", "23", "42", "P0"].contains(where: code.hasPrefix) { return .rejected(code: code) }
    return .server(code: code)
  }

  /// Classe un statut HTTP pour les réponses sans code PostgREST. Un 403 de passerelle reste réessayable :
  /// le traiter comme un refus RLS ferait disparaître une coche jamais reçue.
  static func fromHTTP(status: Int) -> RemoteError {
    status == 401 ? .unauthorized : .server(code: String(status))
  }

  /// Erreur d'une réponse en échec dont le corps ne porte pas de `code` : son statut se perdrait ensuite.
  /// `nil` si la réponse a réussi ou si le code PostgREST suffit.
  static func uncodedFailure(status: Int, body: Data) -> RemoteError? {
    guard status >= 400 else { return nil }
    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    return json?["code"] is String ? nil : fromHTTP(status: status)
  }
}

/// Correspondance entre les identifiants partagés (`shared/categories/`, slug serveur) et l'`Int16` serveur,
/// qui ne doit jamais être écrit en dur ni sortir du gateway.
nonisolated struct CategoryMap: Sendable, Equatable {
  /// Délai avant de relire la table pour un slug qu'elle ne connaissait pas.
  static let missingSlugLifetime: TimeInterval = 3600

  private let idsBySlug: [String: Int16]
  private let slugsById: [Int16: String]
  /// Cache négatif : sans lui, chaque coche d'un slug inconnu relirait la table.
  private(set) var missingSlugs: [String: Date]

  init(rows: [CategoryRow], missingSlugs: [String: Date] = [:]) {
    self.missingSlugs = missingSlugs
    idsBySlug = Dictionary(rows.map { ($0.slug, $0.id) }) { first, _ in first }
    slugsById = Dictionary(rows.map { ($0.id, $0.slug) }) { first, _ in first }
  }

  func remoteId(forSlug slug: String) -> Int16? { idsBySlug[slug] }

  func shouldReload(forSlug slug: String, now: Date) -> Bool {
    guard idsBySlug[slug] == nil else { return false }
    guard let date = missingSlugs[slug] else { return true }
    return now.timeIntervalSince(date) >= Self.missingSlugLifetime
  }

  mutating func markMissing(_ slug: String, at date: Date) {
    missingSlugs[slug] = date
  }

  func slug(forRemoteId id: Int16) -> String? { slugsById[id] }
}

/// Une visite telle que le compte courant la voit.
nonisolated enum VisitAccess: Sendable, Equatable {
  case open
  case closed
  /// Absente ou appartenant à un autre compte : la RLS ne permet pas de distinguer.
  case notVisible
}

/// Accès distant de l'app. `SupabaseGateway` en est l'implémentation ; les tests fournissent une doublure.
/// Toutes les écritures sont idempotentes : la file peut les rejouer. Elles lèvent `RemoteError`.
nonisolated protocol RemoteGateway: Sendable {
  /// Renvoie l'utilisateur courant, et crée un compte anonyme s'il n'y a pas de session. Pendant une suppression de
  /// compte (drapeau `account.deletion`), n'en crée jamais : `unauthorized` sans session.
  @discardableResult
  func ensureSession(captchaToken: String?) async throws -> UUID

  /// Compte de la session existante, sans jamais en créer : `unauthorized` s'il n'y en a pas.
  func currentAccountId() async throws -> UUID
  /// Interroge le serveur : `unauthorized` si la session n'y est plus valable (compte supprimé ailleurs).
  func verifySession() async throws
  /// Compte de la session, même différent du dernier connu. Jamais de création : `unauthorized` sans session,
  /// `keychainLocked` si le Keychain est verrouillé.
  func sessionAccountId() async throws -> UUID
  /// Les données locales ont été réidentifiées pour `id` : il devient le dernier compte connu.
  func acknowledgeAccount(_ id: UUID) async throws
  /// Heure du serveur (en-tête HTTP `Date`), `nil` si la réponse n'en porte pas de lisible.
  func serverDate() async throws -> Date?

  /// Supprime le compte de la session et toutes ses données serveur (RPC `delete_my_account`, #68). Rafraîchit
  /// d'abord la session : le jeton obtenu permet de rejouer l'appel, idempotent, si la réponse se perd. Ne crée
  /// jamais de compte. Après succès, la session est refusée : `verifySession` lève `unauthorized`.
  func deleteAccount() async throws
  /// Oublie la session dans le SDK, sans appel au serveur : elle n'y existe plus.
  func signOutLocally() async throws
  /// Compte de la session enregistrée sur l'appareil, sans appel au serveur : `nil` s'il n'y en a pas.
  /// `keychainLocked` si le Keychain ne peut pas le dire.
  func localSessionAccountId() async throws -> UUID?
  /// Suppression du compte : le serveur prouve-t-il que le compte de la session n'existe plus ? `true` sur
  /// `user_not_found`, `refresh_token_not_found` ou `session_not_found` ; `false` si le compte répond. Tout le reste
  /// lève : le doute demeure. Sans comparaison au dernier compte connu.
  func confirmAccountDeleted() async throws -> Bool

  func saveList(_ list: ListUpsert) async throws
  func deleteList(id: UUID) async throws
  func saveItem(_ item: ListItemUpsert) async throws
  func deleteItem(id: UUID) async throws

  func createVisit(_ visit: VisitInsert) async throws
  func insertChecks(_ checks: [CheckUpload]) async throws
  func closeVisit(id: UUID, endedAt: Date) async throws
  /// Ce que la RLS laisse voir d'une visite : distingue une coche tardive d'une visite d'un autre compte.
  func visitAccess(id: UUID) async throws -> VisitAccess

  /// `updatedAfter` a un recouvrement de quelques secondes : l'appelant doit fusionner de façon idempotente.
  func fetchLists(updatedAfter: Date?) async throws -> [ListRow]
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow]
  func fetchCategories() async throws -> [CategoryRow]
  func fetchProducts() async throws -> [RemoteProduct]

  /// Produits partagés des libellés saisis librement (RPC `resolve_products`), créés au besoin par le serveur.
  /// Au plus `SyncRetryPolicy.maxResolutionBatch` entrées ; une ligne par entrée, dans l'ordre.
  func resolveProducts(_ items: [ProductResolutionRequest]) async throws -> [ResolvedProductRow]

  /// La position n'est ni conservée ni journalisée ici.
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow]

  /// Repli sans position (refus de localisation) : RPC `search_stores`, par nom ou adresse.
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow]

  /// Rayon bio d'un magasin connu par son identifiant. `nil` si le serveur ne le connaît pas.
  func storeOrganicAisle(id: UUID) async throws -> Bool?

  /// Instantané du graphe d'un magasin, s'il diffère de `knownVersion`. Exige une session, jamais créée ici.
  func graphSnapshot(storeId: UUID, knownVersion: Int64?) async throws -> GraphSnapshotResponse
}
