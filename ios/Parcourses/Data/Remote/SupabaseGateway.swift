import Foundation
import Supabase

/// Session `supabase-swift` persistée dans le Keychain, jamais dans `UserDefaults`.
nonisolated struct KeychainAuthStorage: AuthLocalStorage {
  let keychain: KeychainStore

  func store(key: String, value: Data) throws { try keychain.set(value, forKey: key) }
  func retrieve(key: String) throws -> Data? { try keychain.data(forKey: key) }
  func remove(key: String) throws { try keychain.removeValue(forKey: key) }
}

/// Seul type de l'app à importer Supabase.
actor SupabaseGateway: RemoteGateway {
  private let client: SupabaseClient
  private let keychain: KeychainStore
  /// Connexion en cours : l'acteur est réentrant, deux appels ne doivent pas créer deux comptes.
  private var signIn: Task<UUID, any Error>?
  private static let availabilityProbeKey = "availability-probe"

  init(configuration: SupabaseConfiguration, keychain: KeychainStore = KeychainStore()) {
    self.keychain = keychain
    client = SupabaseClient(
      supabaseURL: configuration.url,
      supabaseKey: configuration.publishableKey,
      options: SupabaseClientOptions(
        auth: .init(
          storage: KeychainAuthStorage(keychain: keychain),
          emitLocalSessionAsInitialSession: true
        )
      )
    )
  }

  // MARK: - Session

  @discardableResult
  func ensureSession(captchaToken: String? = nil) async throws -> UUID {
    try await mapped { try await self.resolveSession(captchaToken: captchaToken) }
  }

  private func resolveSession(captchaToken: String?) async throws -> UUID {
    if client.auth.currentSession != nil {
      do {
        // Rafraîchit le jeton s'il a expiré. Sans cela, le SDK enverrait la clé publique seule et le
        // refus `42501` qui en résulte ferait passer une coche non reçue pour reçue.
        return try await client.auth.session.user.id
      } catch AuthError.sessionMissing {
        // Session révoquée : on repart sur un nouveau compte anonyme.
      }
    }
    if let signIn { return try await signIn.value }
    // Keychain verrouillé (arrière-plan avant le premier déverrouillage) : `currentSession` est nil alors
    // que la session existe. On échoue ici pour ne pas créer un second compte.
    _ = try keychain.data(forKey: Self.availabilityProbeKey)
    let auth = client.auth
    let task = Task {
      let id = try await auth.signInAnonymously(captchaToken: captchaToken).user.id
      // Session non persistée : les requêtes partiraient sans jeton et seraient refusées en `42501`.
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
        try await self.client.from(ListUpsert.table)
        .update(ListPatch(name: list.name))
        .eq("id", value: list.id)
        .select("id")
        .execute().value
      if updated.isEmpty { try await self.insertIgnoringDuplicates(list, into: ListUpsert.table) }
    }
  }

  func deleteList(id: UUID) async throws {
    try await authorized { _ = try await self.client.from(ListUpsert.table).delete().eq("id", value: id).execute() }
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
        try await self.client.from(ListItemUpsert.table)
        .update(patch)
        .eq("id", value: item.id)
        .select("id")
        .execute().value
      if updated.isEmpty { try await self.insertIgnoringDuplicates(item, into: ListItemUpsert.table) }
    }
  }

  func deleteItem(id: UUID) async throws {
    try await authorized { _ = try await self.client.from(ListItemUpsert.table).delete().eq("id", value: id).execute() }
  }

  // MARK: - Visites et coches

  func createVisit(_ visit: VisitInsert) async throws {
    try await authorized { try await self.insertIgnoringDuplicates(visit, into: VisitInsert.table) }
  }

  func insertChecks(_ checks: [CheckInsert]) async throws {
    guard !checks.isEmpty else { return }
    try await authorized { try await self.insertIgnoringDuplicates(checks, into: CheckInsert.table) }
  }

  /// Sans effet si la visite est déjà close : la RLS ne laisse voir que les visites ouvertes.
  func closeVisit(id: UUID, endedAt: Date) async throws {
    try await authorized {
      _ = try await self.client.from(VisitInsert.table)
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
    try await authorized {
      try await self.client.from(CategoryRow.table).select(Self.selection(of: CategoryRow.self))
        .order("default_rank").execute().value
    }
  }

  func fetchProducts() async throws -> [ProductRow] {
    try await authorized {
      try await self.client.from(ProductRow.table).select(Self.selection(of: ProductRow.self))
        .order("id").execute().value
    }
  }

  func nearbyStores(lat: Double, lng: Double, radiusM: Int, maxResults: Int) async throws -> [NearbyStoreRow] {
    let parameters = NearbyStoresParameters(lat: lat, lng: lng, radiusM: radiusM, maxResults: maxResults)
    return try await authorized {
      try await self.client.rpc("nearby_stores", params: parameters).execute().value
    }
  }

  // MARK: - Outils

  private func fetchUpdated<Row: TableDTO>(_ type: Row.Type, updatedAfter: Date?) async throws -> [Row] {
    try await authorized {
      var query = self.client.from(Row.table).select(Self.selection(of: Row.self))
      if let updatedAfter {
        query = query.gt("updated_at", value: updatedAfter)
      }
      return try await query.order("updated_at").execute().value
    }
  }

  private static func selection<Row: TableDTO>(of type: Row.Type) -> String {
    Row.columns.joined(separator: ",")
  }

  /// `on conflict (id) do nothing` : un renvoi après une perte de réseau ne crée pas de doublon.
  private func insertIgnoringDuplicates(_ values: some Encodable & Sendable, into table: String) async throws {
    try await client.from(table)
      .upsert(values, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
      .execute()
  }

  /// Toute requête passe par une session valide, puis ses erreurs sont classées.
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

  private static func classify(_ error: any Error) -> RemoteError {
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

  private static func classify(_ error: AuthError) -> RemoteError {
    guard case .api(_, _, _, let response) = error else { return .unauthorized }
    // Côté Auth, un 403 signifie une session refusée, pas un refus RLS.
    let status = response.statusCode
    return status == 403 ? .unauthorized : RemoteError.fromHTTP(status: status)
  }
}

// Colonnes modifiables uniquement : `id` n'a pas le privilège UPDATE, et un upsert PostgREST
// classique le réécrirait (`on conflict do update set id = …`), d'où mise à jour puis insertion.
private nonisolated struct ListPatch: Encodable, Sendable {
  let name: String
}

private nonisolated struct ListItemPatch: Encodable, Sendable {
  let listId: UUID
  let productId: UUID?
  let label: String
  let quantity: String?
  let checkedAt: Date?

  enum CodingKeys: String, CodingKey {
    case label, quantity
    case listId = "list_id"
    case productId = "product_id"
    case checkedAt = "checked_at"
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(listId, forKey: .listId)
    try container.encode(productId, forKey: .productId)
    try container.encode(label, forKey: .label)
    try container.encode(quantity, forKey: .quantity)
    try container.encode(checkedAt, forKey: .checkedAt)
  }
}

private nonisolated struct VisitClose: Encodable, Sendable {
  let endedAt: Date

  enum CodingKeys: String, CodingKey {
    case endedAt = "ended_at"
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
