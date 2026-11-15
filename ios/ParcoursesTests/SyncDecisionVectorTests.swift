import Foundation
import Testing

@testable import Parcourses

private final class VectorBundleToken {}

/// Fichier de `shared/test-vectors/sync/`, copié dans le bundle de test (le simulateur ne lit pas toujours le dépôt).
nonisolated struct SyncVectorFile: Sendable, CustomTestStringConvertible {
  let name: String
  let data: Data

  var testDescription: String { name }

  static let all: [SyncVectorFile] = {
    guard let directory = Bundle(for: VectorBundleToken.self).url(forResource: "sync", withExtension: nil),
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in (try? Data(contentsOf: url)).map { SyncVectorFile(name: url.lastPathComponent, data: $0) } }
  }()
}

/// Les décisions de `SyncDecisions` contre les vecteurs communs avec Android (#87). Un fichier dont la fonction est
/// inconnue fait échouer le test : un vecteur ajouté doit être pris en charge des deux côtés.
struct SyncDecisionVectorTests {
  private struct UnknownFunction: Error, CustomStringConvertible {
    let name: String
    var description: String { "fonction inconnue : \(name)" }
  }

  private struct Malformed: Error, CustomStringConvertible {
    let field: String
    var description: String { "champ illisible : \(field)" }
  }

  @Test func everyFunctionOfTheContractHasItsVectors() throws {
    let functions = try SyncVectorFile.all.map { file in
      let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
      return try #require(object["function"] as? String)
    }
    #expect(
      Set(functions) == [
        "itemSaveRequest", "mergeChangedFields", "zeroRowOutcome", "insertRefusedOutcome", "reconcileLists",
        "applyTombstones", "tombstonePullMode", "rekeyPlan", "sessionLossAction", "linkEmailNextStep",
      ])
  }

  @Test(arguments: SyncVectorFile.all)
  func vectorFileMatches(_ file: SyncVectorFile) throws {
    let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
    let function = try #require(object["function"] as? String)
    let cases = try #require(object["cases"] as? [[String: Any]])
    #expect(!cases.isEmpty)
    for testCase in cases {
      let name = testCase["name"] as? String ?? "?"
      let input = try #require(testCase["input"] as? [String: Any], "\(file.name) · \(name)")
      let expected = try #require(testCase["expected"], "\(file.name) · \(name)")
      let actual = try Self.evaluate(function, input: input)
      #expect((actual as AnyObject).isEqual(expected), "\(file.name) · \(name) : \(actual) ≠ \(expected)")
    }
  }

  /// Sortie au format des vecteurs : noms des cas d'enum, UUID en minuscules.
  private static func evaluate(_ function: String, input: [String: Any]) throws -> Any {
    switch function {
    case "itemSaveRequest":
      switch SyncDecisions.itemSaveRequest(
        isOnServer: try bool(input, "isOnServer"), changedFields: try strings(input, "changedFields"))
      {
      case .insert: return ["kind": "insert"]
      case .patch(let fields): return ["kind": "patch", "fields": fields]
      case .none: return ["kind": "none"]
      }
    case "mergeChangedFields":
      let pending = input["pending"] is NSNull ? nil : try strings(input, "pending")
      return SyncDecisions.mergeChangedFields(pending: pending, new: try strings(input, "new"))
    case "zeroRowOutcome":
      return SyncDecisions.zeroRowOutcome(
        tombstoned: try bool(input, "tombstoned"), listOwnedByMe: try bool(input, "listOwnedByMe")
      ).rawValue
    case "insertRefusedOutcome":
      return SyncDecisions.insertRefusedOutcome(
        listSynced: try bool(input, "listSynced"), listOwnedByMe: try bool(input, "listOwnedByMe")
      ).rawValue
    case "reconcileLists":
      let local = try (input["local"] as? [[String: Any]] ?? []).map {
        LocalListState(id: try uuid($0, "id"), syncedOnce: try bool($0, "syncedOnce"))
      }
      let result = SyncDecisions.reconcileLists(local: local, accessible: try uuids(input, "accessible"))
      return ["remove": lowercased(result.remove), "fetchFully": lowercased(result.fetchFully)]
    case "applyTombstones":
      let delete = SyncDecisions.applyTombstones(
        localItems: try uuids(input, "localItems"), tombstones: try uuids(input, "tombstones"))
      return ["delete": lowercased(delete)]
    case "tombstonePullMode":
      let cursor = input["cursor"] is NSNull ? nil : try date(input, "cursor")
      return SyncDecisions.tombstonePullMode(cursor: cursor, now: try date(input, "now")).rawValue
    case "rekeyPlan":
      guard let list = input["list"] as? [String: Any], let itemCount = list["itemCount"] as? Int else {
        throw Malformed(field: "list")
      }
      let state = RekeyListState(
        ownerId: list["ownerId"] is NSNull ? nil : try uuid(list, "ownerId"), deleted: try bool(list, "deleted"),
        itemCount: itemCount, createdAt: try date(list, "createdAt"),
        updatedAt: try date(list, "updatedAt"))
      return SyncDecisions.rekeyPlan(previousAccountId: try uuid(input, "previousAccountId"), list: state).rawValue
    case "sessionLossAction":
      guard let kind = (input["accountKind"] as? String).flatMap(AccountKind.init(rawValue:)) else {
        throw Malformed(field: "accountKind")
      }
      return SyncDecisions.sessionLossAction(accountKind: kind).rawValue
    case "linkEmailNextStep":
      guard let status = input["status"] as? Int else { throw Malformed(field: "status") }
      return SyncDecisions.linkEmailNextStep(status: status, errorCode: input["errorCode"] as? String).rawValue
    default:
      throw UnknownFunction(name: function)
    }
  }

  private static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
    guard let value = object[key] as? Bool else { throw Malformed(field: key) }
    return value
  }

  private static func strings(_ object: [String: Any], _ key: String) throws -> [String] {
    guard let value = object[key] as? [String] else { throw Malformed(field: key) }
    return value
  }

  private static func uuid(_ object: [String: Any], _ key: String) throws -> UUID {
    guard let value = (object[key] as? String).flatMap(UUID.init(uuidString:)) else { throw Malformed(field: key) }
    return value
  }

  private static func uuids(_ object: [String: Any], _ key: String) throws -> [UUID] {
    try strings(object, key).map { text in
      guard let id = UUID(uuidString: text) else { throw Malformed(field: key) }
      return id
    }
  }

  private static func date(_ object: [String: Any], _ key: String) throws -> Date {
    guard let value = (object[key] as? String).flatMap({ try? Date.ISO8601FormatStyle().parse($0) }) else {
      throw Malformed(field: key)
    }
    return value
  }

  private static func lowercased(_ ids: [UUID]) -> [String] {
    ids.map { $0.uuidString.lowercased() }
  }
}
