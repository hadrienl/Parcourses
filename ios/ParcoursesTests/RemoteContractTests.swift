import Foundation
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
  private static let tablesWithoutDTO: Set<String> = ["stores", "store_edges", "store_entries", "store_stats"]

  /// Colonnes accordées à `authenticated` en écriture (`20261031140005_privileges.sql`).
  private static let writeDTOs: [(type: any TableDTO.Type, columns: Set<String>)] = [
    (ListUpsert.self, ["id", "name"]),
    (ListItemUpsert.self, ["id", "list_id", "label", "quantity", "product_id", "checked_at"]),
    (VisitInsert.self, ["id", "store_id", "list_id", "list_was_sorted", "started_at"]),
    (CheckInsert.self, ["id", "visit_id", "product_id", "category_id", "checked_at"]),
  ]

  private static let readDTOs: [any TableDTO.Type] = [
    ListRow.self, ListItemRow.self, VisitRow.self, CheckRow.self, CategoryRow.self, ProductRow.self,
  ]

  @Test func readDTOsCoverExactlyTheColumnsOfTheirTable() throws {
    for dto in Self.readDTOs {
      let columns = try #require(Self.contract[dto.table], "table \(dto.table) absente du contrat")
      #expect(Set(dto.columns) == Set(columns), "\(dto) ≠ \(dto.table)")
    }
  }

  @Test func writeDTOsSendOnlyGrantedColumnsThatExist() throws {
    for (dto, granted) in Self.writeDTOs {
      let columns = try #require(Self.contract[dto.table], "table \(dto.table) absente du contrat")
      #expect(Set(dto.columns) == granted, "\(dto)")
      #expect(granted.isSubset(of: columns), "\(dto) ⊄ \(dto.table)")
    }
  }

  /// Une nouvelle table dans le schéma doit recevoir un DTO ou être écartée explicitement.
  @Test func everyTableIsAccountedFor() {
    let covered = Set(Self.readDTOs.map { $0.table }).union(Self.tablesWithoutDTO)
    #expect(covered == Set(Self.contract.keys))
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
    ("23503", .constraint(code: "23503")),
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
    (403, .forbidden),
    (404, .rejected(code: "404")),
    (429, .server(code: "429")),
    (503, .server(code: "503")),
  ])
  func classifiesHTTPStatuses(status: Int, expected: RemoteError) {
    #expect(RemoteError.fromHTTP(status: status) == expected)
  }
}

struct SupabaseConfigurationTests {
  @Test func refusesAnEmptyEnvironment() {
    #expect(SupabaseConfiguration(url: "", publishableKey: "") == nil)
    #expect(SupabaseConfiguration(url: nil, publishableKey: "k") == nil)
    #expect(SupabaseConfiguration(url: "http://127.0.0.1:56321", publishableKey: "") == nil)
    #expect(SupabaseConfiguration(url: "ftp://example.org", publishableKey: "k") == nil)
  }

  @Test func acceptsAValidEnvironment() {
    let configuration = SupabaseConfiguration(url: "http://127.0.0.1:56321", publishableKey: "k")
    #expect(configuration?.url.port == 56321)
  }
}
