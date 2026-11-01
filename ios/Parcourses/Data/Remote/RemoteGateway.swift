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
  /// visibles, et un enregistrement « réussirait » sans rien écrire. La reprise se décide en 9.7.
  case accountChanged
  /// Catégorie absente de la table serveur, même après relecture. Réessayable : le serveur peut être en
  /// retard sur `shared/categories/`, et la coche ne doit pas être perdue.
  case unknownCategory(String)

  /// `true` si l'élément doit rester dans la file.
  var isRetryable: Bool {
    switch self {
    case .network, .unauthorized, .dependencyMissing, .server, .unexpected, .accountChanged, .unknownCategory:
      true
    case .forbidden, .constraint, .rejected:
      false
    }
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
    switch status {
    case 401: .unauthorized
    case 403, 408, 429, 500...: .server(code: String(status))
    default: .rejected(code: String(status))
    }
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
  private let idsBySlug: [String: Int16]
  private let slugsById: [Int16: String]

  init(rows: [CategoryRow]) {
    idsBySlug = Dictionary(rows.map { ($0.slug, $0.id) }) { first, _ in first }
    slugsById = Dictionary(rows.map { ($0.id, $0.slug) }) { first, _ in first }
  }

  func remoteId(forSlug slug: String) -> Int16? { idsBySlug[slug] }
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
  /// Renvoie l'utilisateur courant, et crée un compte anonyme s'il n'y a pas de session.
  @discardableResult
  func ensureSession(captchaToken: String?) async throws -> UUID

  /// Accepte le compte courant après `accountChanged`, une fois la reprise décidée par l'appelant.
  func acceptCurrentAccount() async throws

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

  /// La position n'est ni conservée ni journalisée ici.
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow]

  /// Repli sans position (refus de localisation) : RPC `search_stores`, par nom ou adresse.
  func searchStores(query: String, limit: Int) async throws -> [StoreSearchRow]
}
