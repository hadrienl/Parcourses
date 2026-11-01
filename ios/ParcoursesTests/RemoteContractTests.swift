import Foundation
import Supabase
import Testing

@testable import Parcourses

/// Les DTO sont confrontés à `shared/contract/tables.json`, régénéré depuis le schéma (#8).
private final class BundleToken {}

struct RemoteContractTests {
  /// Copié dans le bundle de test à la compilation : le simulateur ne lit pas toujours le dépôt (TCC).
  private static let contract: [String: [String]] = {
    guard
      let url = Bundle(for: BundleToken.self).url(forResource: "tables", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let tables = try? JSONDecoder().decode([String: [String]].self, from: data)
    else { return [:] }
    return tables
  }()

  /// Tables que l'app ne lit pas directement : magasins par RPC, graphe écrit et servi par le serveur.
  private static let tablesWithoutDTO: Set<String> = [
    "stores", "store_edges", "store_entries", "store_stats", "store_graph_snapshots",
  ]

  /// Colonnes accordées à `authenticated` : `verb` vaut `insert` ou `update`, lues dans les migrations.
  private static func granted(_ verb: String, on table: String) throws -> Set<String> {
    let directory = try #require(Bundle(for: BundleToken.self).url(forResource: "migrations", withExtension: nil))
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let pattern = try Regex("grant\\s+\(verb)\\s*\\(([^)]*)\\)\\s+on\\s+public\\.\(table)\\b")
    var columns: Set<String> = []
    for file in files where file.pathExtension == "sql" {
      for match in try String(contentsOf: file, encoding: .utf8).matches(of: pattern) {
        let list = try #require(match.output[1].substring)
        columns.formUnion(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      }
    }
    return columns
  }

  private static func encodedKeys(_ value: some Encodable) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    return Set(try #require(object as? [String: Any]).keys)
  }

  /// Colonnes internes au calcul du graphe (#11), que l'app ne lit pas. Toute autre colonne doit avoir son DTO.
  private static let serverOnlyColumns: [String: Set<String>] = [
    "visits": [
      "auto_closed", "learn_outcome", "learn_weight", "next_attempt_at", "process_attempts", "process_error",
      "processed_algo_version",
    ]
  ]

  private static let id = UUID()
  private static let writeSamples: [(table: String, columns: [String], value: any Encodable)] = [
    (ListUpsert.table, ListUpsert.columns, ListUpsert(id: id, name: "n")),
    (
      ListItemUpsert.table, ListItemUpsert.columns,
      ListItemUpsert(id: id, listId: id, productId: nil, label: "l", quantity: nil, checkedAt: nil)
    ),
    (
      VisitInsert.table, VisitInsert.columns,
      VisitInsert(id: id, storeId: id, listId: id, listWasSorted: false, startedAt: .now)
    ),
    (
      CheckInsert.table, CheckInsert.columns,
      CheckInsert(id: id, visitId: id, target: .product(id), checkedAt: .now)
    ),
  ]

  private static let readDTOs: [any TableDTO.Type] = [
    ListRow.self, ListItemRow.self, VisitRow.self, CheckRow.self, CategoryRow.self, ProductRow.self,
  ]

  @Test func readDTOsCoverExactlyTheColumnsOfTheirTable() throws {
    for dto in Self.readDTOs {
      let columns = try #require(Self.contract[dto.table], "table \(dto.table) absente du contrat")
      let expected = Set(columns).subtracting(Self.serverOnlyColumns[dto.table, default: []])
      #expect(Set(dto.columns) == expected, "\(dto) ≠ \(dto.table)")
    }
  }

  @Test func writeDTOsEncodeExactlyTheirColumnsAndOnlyGrantedOnes() throws {
    for sample in Self.writeSamples {
      let columns = try #require(Self.contract[sample.table], "table \(sample.table) absente du contrat")
      let keys = try Self.encodedKeys(sample.value)
      #expect(keys == Set(sample.columns), "\(sample.table)")
      #expect(keys == (try Self.granted("insert", on: sample.table)), "\(sample.table)")
      #expect(keys.isSubset(of: columns), "\(sample.table)")
    }
  }

  @Test func patchesEncodeOnlyColumnsGrantedForUpdate() throws {
    let id = UUID()
    let item = ListItemPatch(listId: id, productId: nil, label: "l", quantity: nil, checkedAt: nil)
    #expect(try Self.encodedKeys(ListPatch(name: "n")) == (try Self.granted("update", on: "lists")))
    #expect(try Self.encodedKeys(item) == (try Self.granted("update", on: "list_items")))
    #expect(try Self.encodedKeys(VisitClose(endedAt: .now)) == (try Self.granted("update", on: "visits")))
  }

  // JSON figés, dans la forme renvoyée par PostgREST (microsecondes et décalage horaire).
  private static let uuid = "11111111-1111-1111-1111-111111111111"
  private static let date = "2026-10-31T10:00:00.123456+00:00"

  private func decode<Row: Decodable>(_ type: Row.Type, _ json: String) throws -> Row {
    try PostgrestClient.Configuration.jsonDecoder.decode(Row.self, from: Data(json.utf8))
  }

  @Test func rowsDecodeFrozenPostgrestJSON() throws {
    let (u, d) = (Self.uuid, Self.date)
    let list = try decode(
      ListRow.self, #"{"id":"\#(u)","owner_id":"\#(u)","name":"C","created_at":"\#(d)","updated_at":"\#(d)"}"#)
    #expect(list.name == "C")
    let item = try decode(
      ListItemRow.self,
      #"{"id":"\#(u)","list_id":"\#(u)","product_id":null,"label":"Lait","quantity":null,"checked_at":"\#(d)","created_at":"\#(d)","updated_at":"\#(d)"}"#
    )
    #expect(item.checkedAt != nil && item.quantity == nil)
    let visit = try decode(
      VisitRow.self,
      #"{"id":"\#(u)","user_id":"\#(u)","store_id":"\#(u)","list_id":null,"list_was_sorted":true,"started_at":"\#(d)","ended_at":null,"processed_at":null}"#
    )
    #expect(visit.listWasSorted && visit.endedAt == nil)
    let check = try decode(
      CheckRow.self,
      #"{"id":"\#(u)","visit_id":"\#(u)","product_id":null,"category_id":4,"checked_at":"\#(d)","ignored":false}"#)
    #expect(check.categoryId == 4)
    let category = try decode(CategoryRow.self, #"{"id":4,"slug":"dairy","name":"Crèmerie","default_rank":70}"#)
    #expect(category.defaultRank == 70)
    let product = try decode(
      ProductRow.self,
      #"{"id":"\#(u)","name":"Lait","normalized_name":"lait","category_id":4,"off_code":null,"created_at":"\#(d)"}"#)
    #expect(product.normalizedName == "lait")
    let store = try decode(
      NearbyStoreRow.self,
      #"{"id":"\#(u)","name":"S","chain":null,"address":null,"distance_m":12.5,"organic_aisle":false}"#)
    #expect(store.distanceM == 12.5)
    let found = try decode(
      StoreSearchRow.self, #"{"id":"\#(u)","name":"S","chain":null,"address":"A","organic_aisle":false}"#)
    #expect(found.address == "A")
  }

  /// Une nouvelle table dans le schéma doit recevoir un DTO ou être écartée explicitement.
  @Test func everyTableIsAccountedFor() {
    let covered = Set(Self.readDTOs.map { $0.table }).union(Self.tablesWithoutDTO)
    #expect(covered == Set(Self.contract.keys))
  }

  @Test func categoryMapTranslatesBothWays() {
    let map = CategoryMap(rows: [CategoryRow(id: 4, slug: "dairy", name: "C", defaultRank: 70)])
    #expect(map.remoteId(forSlug: "dairy") == 4)
    #expect(map.slug(forRemoteId: 4) == "dairy")
    #expect(map.remoteId(forSlug: "other") == nil)
  }

  @Test func checkEncodesExplicitNullsSoBatchesAreUniform() throws {
    let check = CheckInsert(id: UUID(), visitId: UUID(), target: .category(3), checkedAt: .now)
    let data = try JSONEncoder().encode(check)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["product_id"] is NSNull)
    #expect(object["category_id"] as? Int == 3)
  }
}

struct RemoteErrorTests {
  @Test(arguments: [
    ("42501", RemoteError.forbidden),
    ("23514", .constraint(code: "23514")),
    ("23505", .constraint(code: "23505")),
    ("23503", .dependencyMissing(code: "23503")),
    ("23502", .rejected(code: "23502")),
    ("PGRST301", .unauthorized),
    ("PGRST303", .unauthorized),
    ("PGRST001", .server(code: "PGRST001")),
    ("PGRST204", .rejected(code: "PGRST204")),
    ("22023", .rejected(code: "22023")),
    ("57014", .server(code: "57014")),
  ])
  func classifiesPostgrestCodes(code: String, expected: RemoteError) {
    #expect(RemoteError.fromPostgrest(code: code) == expected)
  }

  @Test(arguments: [
    (401, RemoteError.unauthorized),
    (403, .server(code: "403")),
    (404, .rejected(code: "404")),
    (429, .server(code: "429")),
    (503, .server(code: "503")),
  ])
  func classifiesHTTPStatuses(status: Int, expected: RemoteError) {
    #expect(RemoteError.fromHTTP(status: status) == expected)
  }
}

struct RemoteClassificationTests {
  private static let url = URL(string: "http://127.0.0.1")!

  private func authError(_ code: ErrorCode, status: Int) -> AuthError {
    .api(
      message: "m", errorCode: code, underlyingData: Data(),
      underlyingResponse: HTTPURLResponse(url: Self.url, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }

  @Test func onlyTheCodeMakesAForbidden() {
    let body = Data(#"{"message":"blocked"}"#.utf8)
    #expect(RemoteError.uncodedFailure(status: 403, body: body) == .server(code: "403"))
    #expect(RemoteError.uncodedFailure(status: 401, body: body) == .unauthorized)
    #expect(RemoteError.uncodedFailure(status: 502, body: Data("<html>".utf8)) == .server(code: "502"))
    #expect(RemoteError.uncodedFailure(status: 403, body: Data(#"{"code":"42501","message":"m"}"#.utf8)) == nil)
    #expect(RemoteError.uncodedFailure(status: 201, body: Data()) == nil)
    #expect(RemoteError.forbidden.isRetryable == false)
    #expect(RemoteError.unexpected.isRetryable)
  }

  @Test func classifiesEveryErrorFamily() {
    #expect(SupabaseGateway.classify(RemoteError.accountChanged) == .accountChanged)
    #expect(SupabaseGateway.classify(PostgrestError(code: "42501", message: "m")) == .forbidden)
    #expect(SupabaseGateway.classify(PostgrestError(message: "m")) == .unexpected)
    #expect(SupabaseGateway.classify(URLError(.notConnectedToInternet)) == .network)
    #expect(SupabaseGateway.classify(CancellationError()) == .network)
    #expect(SupabaseGateway.classify(KeychainError(status: -25308)) == .unauthorized)
    #expect(SupabaseGateway.classify(CocoaError(.fileNoSuchFile)) == .unexpected)
  }

  @Test(arguments: [ErrorCode.refreshTokenNotFound, .refreshTokenAlreadyUsed, .sessionNotFound])
  func aLostSessionIsUnauthorizedAndAllowsANewAccount(code: ErrorCode) {
    let error = authError(code, status: 400)
    #expect(SupabaseGateway.isSessionGone(error))
    #expect(SupabaseGateway.classify(error as any Error) == .unauthorized)
  }

  @Test func otherAuthFailuresKeepTheirStatus() {
    let rateLimited = authError(ErrorCode("over_request_rate_limit"), status: 429)
    #expect(SupabaseGateway.isSessionGone(rateLimited) == false)
    #expect(SupabaseGateway.classify(rateLimited as any Error) == .server(code: "429"))
    #expect(SupabaseGateway.classify(AuthError.sessionMissing as any Error) == .unauthorized)
  }
}

struct SupabaseConfigurationTests {
  @Test func refusesAnEmptyEnvironment() {
    #expect(SupabaseConfiguration(url: "", publishableKey: "") == nil)
    #expect(SupabaseConfiguration(url: nil, publishableKey: "k") == nil)
    #expect(SupabaseConfiguration(url: "http://127.0.0.1:56321", publishableKey: "") == nil)
    #expect(SupabaseConfiguration(url: "ftp://example.org", publishableKey: "k") == nil)
    #expect(SupabaseConfiguration(url: "http://example.org", publishableKey: "k") == nil)
    #expect(SupabaseConfiguration(url: "https://example.org", publishableKey: "k") != nil)
  }

  @Test func acceptsAValidEnvironment() {
    let configuration = SupabaseConfiguration(url: "http://127.0.0.1:56321", publishableKey: "k")
    #expect(configuration?.url.port == 56321)
  }
}
