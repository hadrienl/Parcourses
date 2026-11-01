import Foundation

/// Erreur distante classée pour la file d'envoi (9.7, contrat hors ligne de `docs/data-model.md`).
nonisolated enum RemoteError: Error, Sendable, Equatable {
  /// Pas de réseau ou requête interrompue : à réessayer.
  case network
  /// Session absente ou expirée : à réessayer après rafraîchissement.
  case unauthorized
  /// `42501` : refus RLS ou privilège. Sur une coche, elle est considérée comme reçue.
  case forbidden
  /// Classe `23` (`23514`…) : renvoyer la même ligne ne changerait rien.
  case constraint(code: String)
  /// Requête invalide, définitive.
  case rejected(code: String)
  /// Erreur côté serveur : à réessayer.
  case server(code: String)
  /// Réponse illisible.
  case unexpected

  /// Classe un code renvoyé par PostgREST (SQLSTATE ou `PGRSTxxx`).
  static func fromPostgrest(code: String?) -> RemoteError {
    guard let code else { return .unexpected }
    if code == "42501" { return .forbidden }
    if code.hasPrefix("23") { return .constraint(code: code) }
    if ["PGRST301", "PGRST302", "PGRST303"].contains(code) { return .unauthorized }
    // PGRST0xx : base injoignable ou saturée, et PGRST5xx : erreur interne.
    if code.hasPrefix("PGRST0") || code.hasPrefix("PGRST5") { return .server(code: code) }
    // Autres PGRST : requête mal formée ; 22, 42, P0 : données ou SQL refusés.
    if code.hasPrefix("PGRST") || code.hasPrefix("22") || code.hasPrefix("42") || code.hasPrefix("P0") {
      return .rejected(code: code)
    }
    return .server(code: code)
  }

  /// Classe un statut HTTP pour les réponses sans code PostgREST.
  static func fromHTTP(status: Int) -> RemoteError {
    switch status {
    case 401: .unauthorized
    case 403: .forbidden
    case 408, 429, 500...: .server(code: String(status))
    default: .rejected(code: String(status))
    }
  }
}

/// Accès distant de l'app. `SupabaseGateway` en est l'implémentation ; les tests fournissent une doublure.
/// Toutes les écritures sont idempotentes : la file peut les rejouer. Elles lèvent `RemoteError`.
nonisolated protocol RemoteGateway: Sendable {
  /// Renvoie l'utilisateur courant, et crée un compte anonyme s'il n'y a pas de session.
  @discardableResult
  func ensureSession(captchaToken: String?) async throws -> UUID

  func saveList(_ list: ListUpsert) async throws
  func deleteList(id: UUID) async throws
  func saveItem(_ item: ListItemUpsert) async throws
  func deleteItem(id: UUID) async throws

  func createVisit(_ visit: VisitInsert) async throws
  func insertChecks(_ checks: [CheckInsert]) async throws
  func closeVisit(id: UUID, endedAt: Date) async throws

  func fetchLists(updatedAfter: Date?) async throws -> [ListRow]
  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow]
  func fetchCategories() async throws -> [CategoryRow]
  func fetchProducts() async throws -> [ProductRow]

  /// La position n'est ni conservée ni journalisée ici.
  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow]
}
