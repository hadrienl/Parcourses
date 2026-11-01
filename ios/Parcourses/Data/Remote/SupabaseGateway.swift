import Foundation
import Supabase

/// Session `supabase-swift` persistée dans le Keychain, jamais dans `UserDefaults`.
nonisolated struct KeychainAuthStorage: AuthLocalStorage {
  let store: any SecureStore

  func store(key: String, value: Data) throws { try store.set(value, forKey: key) }
  func retrieve(key: String) throws -> Data? { try store.data(forKey: key) }
  func remove(key: String) throws { try store.removeValue(forKey: key) }
}

/// Seul type de l'app à importer Supabase.
actor SupabaseGateway: RemoteGateway {
  /// Clé du dernier compte connu, à côté de la session.
  static let lastAccountKey = "last-account-id"
  /// Recouvrement du curseur : deux transactions proches peuvent valider dans le désordre.
  static let cursorOverlap: TimeInterval = 5
  /// `max_rows` côté serveur. La pagination avance du nombre de lignes reçues : un plafond plus bas passe aussi.
  private static let pageSize = 1000

  private let client: SupabaseClient
  private let rest: PostgrestClient
  private let store: any SecureStore
  /// Connexion en cours : l'acteur est réentrant, deux appels ne doivent pas créer deux comptes.
  private var signIn: Task<UUID, any Error>?
  private var categoryMap: CategoryMap?

  init(configuration: SupabaseConfiguration, store: any SecureStore = KeychainStore()) {
    self.store = store
    let client = SupabaseClient(
      supabaseURL: configuration.url,
      supabaseKey: configuration.publishableKey,
      options: SupabaseClientOptions(
        auth: .init(
          storage: KeychainAuthStorage(store: store),
          emitLocalSessionAsInitialSession: true
        )
      )
    )
    self.client = client
    let auth = client.auth
    // Client dédié plutôt que `client.from` : celui-ci retomberait sur la clé publique seule si le jeton
    // manque, et le `42501` obtenu ferait passer une coche non reçue pour reçue. Il perdrait aussi le statut
    // HTTP d'une réponse sans `code`.
    rest = PostgrestClient(
      url: configuration.url.appending(path: "rest/v1"),
      headers: ["apikey": configuration.publishableKey],
      fetch: { request in
        var request = request
        let token = try await auth.session.accessToken
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
          let failure = RemoteError.uncodedFailure(status: http.statusCode, body: data)
        {
          throw failure
        }
        return (data, response)
      }
    )
  }

  // MARK: - Session

  @discardableResult
  func ensureSession(captchaToken: String? = nil) async throws -> UUID {
    try await mapped { try await self.resolveSession(captchaToken: captchaToken) }
  }

  func acceptCurrentAccount() async throws {
    try await mapped {
      let id = try await self.currentOrNewUser(captchaToken: nil)
      try self.store.set(Data(id.uuidString.utf8), forKey: Self.lastAccountKey)
    }
  }

  private func resolveSession(captchaToken: String?) async throws -> UUID {
    let id = try await currentOrNewUser(captchaToken: captchaToken)
    let known = try store.data(forKey: Self.lastAccountKey).flatMap { String(bytes: $0, encoding: .utf8) }
    if let known {
      guard known == id.uuidString else { throw RemoteError.accountChanged }
    } else {
      try store.set(Data(id.uuidString.utf8), forKey: Self.lastAccountKey)
    }
    return id
  }

  private func currentOrNewUser(captchaToken: String?) async throws -> UUID {
    let auth = client.auth
    if auth.currentSession != nil {
      do {
        return try await auth.session.user.id
      } catch let error as AuthError where Self.isSessionGone(error) {
        // Le SDK garde la session sur certains échecs : on ne crée un compte que si elle a disparu.
        guard auth.currentSession == nil else { throw error }
      }
    }
    if let signIn { return try await signIn.value }
    // Keychain verrouillé (arrière-plan avant le premier déverrouillage) : `currentSession` est nil alors
    // que la session existe. On échoue ici pour ne pas créer un second compte.
    try store.verifyAvailable()
    let task = Task {
      let id = try await auth.signInAnonymously(captchaToken: captchaToken).user.id
      guard auth.currentSession != nil else { throw RemoteError.unauthorized }
      return id
    }
    signIn = task
    defer { signIn = nil }
    return try await task.value
  }

  // MARK: - Listes et articles

  func saveList(_ list: ListUpsert) async throws {
    try await authorized {
      let updated: [IdentifierRow] =
        try await self.rest.from(ListUpsert.table)
        .update(ListPatch(name: list.name))
        .eq("id", value: list.id)
        .select("id")
        .execute().value
      if updated.isEmpty { try await self.insertIgnoringDuplicates(list, into: ListUpsert.table) }
    }
  }

  func deleteList(id: UUID) async throws {
    try await authorized { _ = try await self.rest.from(ListUpsert.table).delete().eq("id", value: id).execute() }
  }

  func saveItem(_ item: ListItemUpsert) async throws {
    try await authorized {
      let patch = ListItemPatch(
        listId: item.listId,
        productId: item.productId,
        label: item.label,
        quantity: item.quantity,
        checkedAt: item.checkedAt
      )
      let updated: [IdentifierRow] =
        try await self.rest.from(ListItemUpsert.table)
        .update(patch)
        .eq("id", value: item.id)
        .select("id")
        .execute().value
      if updated.isEmpty { try await self.insertIgnoringDuplicates(item, into: ListItemUpsert.table) }
    }
  }

  func deleteItem(id: UUID) async throws {
    try await authorized { _ = try await self.rest.from(ListItemUpsert.table).delete().eq("id", value: id).execute() }
  }

  // MARK: - Visites et coches

  func createVisit(_ visit: VisitInsert) async throws {
    try await authorized { try await self.insertIgnoringDuplicates(visit, into: VisitInsert.table) }
  }

  func insertChecks(_ checks: [CheckUpload]) async throws {
    guard !checks.isEmpty else { return }
    try await authorized {
      let rows = try await self.wireChecks(checks)
      try await self.insertIgnoringDuplicates(rows, into: CheckInsert.table)
    }
  }

  private func wireChecks(_ checks: [CheckUpload]) async throws -> [CheckInsert] {
    var map = try await currentCategoryMap()
    var rows: [CheckInsert] = []
    for check in checks {
      switch check.target {
      case .product(let productId):
        rows.append(
          .init(id: check.id, visitId: check.visitId, target: .product(productId), checkedAt: check.checkedAt))
      case .category(let slug):
        if map.remoteId(forSlug: slug) == nil { map = try await reloadCategoryMap() }
        guard let remoteId = map.remoteId(forSlug: slug) else { throw RemoteError.unknownCategory(slug) }
        rows.append(
          .init(id: check.id, visitId: check.visitId, target: .category(remoteId), checkedAt: check.checkedAt))
      }
    }
    return rows
  }

  /// Sans effet si la visite est déjà close : la RLS ne laisse voir que les visites ouvertes.
  func closeVisit(id: UUID, endedAt: Date) async throws {
    try await authorized {
      _ = try await self.rest.from(VisitInsert.table)
        .update(VisitClose(endedAt: endedAt))
        .eq("id", value: id)
        .is("ended_at", value: nil)
        .execute()
    }
  }

  // MARK: - Lecture

  func fetchLists(updatedAfter: Date?) async throws -> [ListRow] {
    try await fetchUpdated(ListRow.self, updatedAfter: updatedAfter)
  }

  func fetchItems(updatedAfter: Date?) async throws -> [ListItemRow] {
    try await fetchUpdated(ListItemRow.self, updatedAfter: updatedAfter)
  }

  func fetchCategories() async throws -> [CategoryRow] {
    try await authorized { try await self.loadCategories() }
  }

  func fetchProducts() async throws -> [RemoteProduct] {
    try await authorized {
      let rows: [ProductRow] = try await self.fetchAllPages { from, to in
        try await self.rest.from(ProductRow.table).select(Self.selection(of: ProductRow.self))
          .order("id").range(from: from, to: to).execute().value
      }
      var map = try await self.currentCategoryMap()
      if rows.contains(where: { row in row.categoryId.map { map.slug(forRemoteId: $0) == nil } ?? false }) {
        map = try await self.reloadCategoryMap()
      }
      return try rows.map { row in
        var slug: String?
        if let categoryId = row.categoryId {
          guard let known = map.slug(forRemoteId: categoryId) else {
            throw RemoteError.unknownCategory(String(categoryId))
          }
          slug = known
        }
        return RemoteProduct(
          id: row.id, name: row.name, normalizedName: row.normalizedName, categorySlug: slug,
          offCode: row.offCode, createdAt: row.createdAt)
      }
    }
  }

  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] {
    let parameters = NearbyStoresParameters(lat: lat, lng: lng, radiusM: radiusM, maxResults: maxResults)
    return try await authorized {
      try await self.rest.rpc("nearby_stores", params: parameters).execute().value
    }
  }

  // MARK: - Outils

  private func loadCategories() async throws -> [CategoryRow] {
    let rows: [CategoryRow] =
      try await rest.from(CategoryRow.table).select(Self.selection(of: CategoryRow.self))
      .order("default_rank").execute().value
    categoryMap = CategoryMap(rows: rows)
    return rows
  }

  private func currentCategoryMap() async throws -> CategoryMap {
    if let categoryMap { return categoryMap }
    return try await reloadCategoryMap()
  }

  private func reloadCategoryMap() async throws -> CategoryMap {
    CategoryMap(rows: try await loadCategories())
  }

  private func fetchUpdated<Row: TableDTO>(_ type: Row.Type, updatedAfter: Date?) async throws -> [Row] {
    try await authorized {
      try await self.fetchAllPages { from, to in
        var query = self.rest.from(Row.table).select(Self.selection(of: Row.self))
        if let updatedAfter {
          query = query.gte("updated_at", value: updatedAfter.addingTimeInterval(-Self.cursorOverlap))
        }
        // `id` départage les lignes de même date : sans lui, une page pourrait en sauter.
        return try await query.order("updated_at").order("id").range(from: from, to: to).execute().value
      }
    }
  }

  private func fetchAllPages<Row: Sendable>(
    _ page: @Sendable (_ from: Int, _ to: Int) async throws -> [Row]
  ) async throws -> [Row] {
    var rows: [Row] = []
    while true {
      let next = try await page(rows.count, rows.count + Self.pageSize - 1)
      if next.isEmpty { return rows }
      rows += next
    }
  }

  private static func selection<Row: TableDTO>(of type: Row.Type) -> String {
    Row.columns.joined(separator: ",")
  }

  /// `on conflict (id) do nothing` : un renvoi après une perte de réseau ne crée pas de doublon.
  private func insertIgnoringDuplicates(_ values: some Encodable & Sendable, into table: String) async throws {
    try await rest.from(table)
      .upsert(values, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
      .execute()
  }

  /// Toute requête passe par une session valide du même compte, puis ses erreurs sont classées.
  private func authorized<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try await mapped {
      _ = try await self.resolveSession(captchaToken: nil)
      return try await operation()
    }
  }

  private func mapped<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    do {
      return try await operation()
    } catch {
      throw Self.classify(error)
    }
  }

  static func classify(_ error: any Error) -> RemoteError {
    switch error {
    case let error as RemoteError: return error
    case let error as PostgrestError: return .fromPostgrest(code: error.code)
    case let error as HTTPError: return .fromHTTP(status: error.response.statusCode)
    case let error as AuthError: return classify(error)
    case is URLError, is CancellationError: return .network
    case is KeychainError: return .unauthorized
    default: return .unexpected
    }
  }

  static func classify(_ error: AuthError) -> RemoteError {
    if isSessionGone(error) { return .unauthorized }
    guard case .api(_, _, _, let response) = error else { return .unauthorized }
    // Côté Auth, un 403 signifie une session refusée.
    let status = response.statusCode
    return status == 403 ? .unauthorized : RemoteError.fromHTTP(status: status)
  }

  /// La session ne reviendra pas : seul un nouveau compte anonyme permet de continuer.
  static func isSessionGone(_ error: AuthError) -> Bool {
    switch error {
    case .sessionMissing:
      return true
    case .api(_, let code, _, _):
      return [.refreshTokenNotFound, .refreshTokenAlreadyUsed, .sessionNotFound].contains(code)
    default:
      return false
    }
  }
}

private nonisolated struct IdentifierRow: Decodable, Sendable {
  let id: UUID
}

private nonisolated struct NearbyStoresParameters: Encodable, Sendable {
  let lat: Double
  let lng: Double
  let radiusM: Int
  let maxResults: Int

  enum CodingKeys: String, CodingKey {
    case lat, lng
    case radiusM = "radius_m"
    case maxResults = "max_results"
  }
}
