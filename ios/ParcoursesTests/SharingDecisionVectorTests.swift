import Foundation
import Testing

@testable import Parcourses

private final class SharingVectorBundleToken {}

/// Fichier de `shared/test-vectors/sharing/`, copié dans le bundle de test.
nonisolated struct SharingVectorFile: Sendable, CustomTestStringConvertible {
  let name: String
  let data: Data

  var testDescription: String { name }

  static let all: [SharingVectorFile] = {
    guard
      let directory = Bundle(for: SharingVectorBundleToken.self).url(forResource: "sharing", withExtension: nil),
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return files.filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        (try? Data(contentsOf: url)).map { SharingVectorFile(name: url.lastPathComponent, data: $0) }
      }
  }()
}

/// `SharingDecisions` contre les vecteurs communs avec Android (#87, lots 87.4 et 87.6). Un fichier dont la fonction
/// est inconnue fait échouer le test : un vecteur ajouté doit être pris en charge des deux côtés.
struct SharingDecisionVectorTests {
  private struct UnknownFunction: Error, CustomStringConvertible {
    let name: String
    var description: String { "fonction inconnue : \(name)" }
  }

  private struct Malformed: Error, CustomStringConvertible {
    let field: String
    var description: String { "champ illisible : \(field)" }
  }

  @Test func everyFunctionOfTheContractHasItsVectors() throws {
    let functions = try SharingVectorFile.all.map { file in
      let object = try #require(try JSONSerialization.jsonObject(with: file.data) as? [String: Any])
      #expect(object["format_version"] as? Int == 1, "\(file.name)")
      return try #require(object["function"] as? String)
    }
    #expect(
      Set(functions) == [
        "parseInvitationLink", "roleCapabilities", "inviteErrorKind", "invitationCardState", "acceptOutcome",
        "signalActions", "memberInitial", "itemAuthorMark",
      ])
  }

  @Test(arguments: SharingVectorFile.all)
  func vectorFileMatches(_ file: SharingVectorFile) throws {
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

  /// Sortie au format des vecteurs : noms des cas d'enum, `NSNull` pour `null`.
  private static func evaluate(_ function: String, input: [String: Any]) throws -> Any {
    switch function {
    case "parseInvitationLink":
      guard let url = input["url"] as? String else { throw Malformed(field: "url") }
      return SharingDecisions.parseInvitationLink(url: url, httpsHost: input["httpsHost"] as? String) ?? NSNull()
    case "roleCapabilities":
      guard let role = (input["role"] as? String).flatMap(ListRole.init(rawValue:)) else {
        throw Malformed(field: "role")
      }
      let capabilities = SharingDecisions.roleCapabilities(role)
      return [
        "canEditItems": capabilities.canEditItems, "canShop": capabilities.canShop, "canShare": capabilities.canShare,
        "canManageMembers": capabilities.canManageMembers, "canLeave": capabilities.canLeave,
        "canRenameList": capabilities.canRenameList, "canDeleteList": capabilities.canDeleteList,
      ]
    case "inviteErrorKind":
      return SharingDecisions.inviteErrorKind(input["error"] as? String).rawValue
    case "invitationCardState":
      guard let status = input["status"] as? String, let matches = input["emailMatches"] as? Bool else {
        throw Malformed(field: "status")
      }
      return SharingDecisions.invitationCardState(status: status, emailMatches: matches).rawValue
    case "acceptOutcome":
      guard let status = input["status"] as? String else { throw Malformed(field: "status") }
      return SharingDecisions.acceptOutcome(status: status).rawValue
    case "signalActions":
      guard let kind = input["kind"] as? String, let open = input["sharingSheetOpen"] as? Bool else {
        throw Malformed(field: "kind")
      }
      return SharingDecisions.signalActions(kind: kind, sharingSheetOpen: open).map(\.rawValue)
    case "memberInitial":
      return SharingDecisions.memberInitial(input["displayName"] as? String)
    case "itemAuthorMark":
      guard let me = (input["me"] as? String).flatMap(UUID.init(uuidString:)),
        let shared = input["shared"] as? Bool, let members = input["members"] as? [[String: Any]]
      else { throw Malformed(field: "me") }
      let candidates = try members.map { member in
        guard let id = (member["userId"] as? String).flatMap(UUID.init(uuidString:)) else {
          throw Malformed(field: "members.userId")
        }
        return AuthorCandidate(userId: id, displayName: member["displayName"] as? String)
      }
      let updatedBy = (input["updatedBy"] as? String).flatMap(UUID.init(uuidString:))
      return SharingDecisions.itemAuthorMark(updatedBy: updatedBy, me: me, shared: shared, members: candidates)
        ?? NSNull()
    default:
      throw UnknownFunction(name: function)
    }
  }
}
