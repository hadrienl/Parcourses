import Foundation
import Testing

@testable import Domain

/// Vecteur partagé de `shared/test-vectors/categorize/`.
struct CategorizeVector: Decodable, Sendable {
  struct Case: Decodable, Sendable {
    let input: String
    let expected: Expected
  }

  struct Expected: Decodable, Sendable {
    let normalized: String
    let categoryId: String
    let matchedKeyword: String?
    let match: String

    enum CodingKeys: String, CodingKey {
      case normalized, match
      case categoryId = "category_id"
      case matchedKeyword = "matched_keyword"
    }
  }

  let id: String
  let formatVersion: Int
  let cases: [Case]

  enum CodingKeys: String, CodingKey {
    case id, cases
    case formatVersion = "format_version"
  }
}

/// Racine du dépôt, retrouvée par chemin relatif depuis ce fichier.
let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // DomainTests
  .deletingLastPathComponent()  // Tests
  .deletingLastPathComponent()  // Domain
  .deletingLastPathComponent()  // Packages
  .deletingLastPathComponent()  // ios
  .deletingLastPathComponent()

/// Tous les vecteurs, triés par nom de fichier.
func loadVectors() throws -> [CategorizeVector] {
  let directory = repositoryRoot.appendingPathComponent("shared/test-vectors/categorize")
  let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
  return try files.map { try JSONDecoder().decode(CategorizeVector.self, from: Data(contentsOf: $0)) }
}

/// Classifieur partagé par les tests, sur le dictionnaire embarqué.
let classifier: CategoryClassifier = {
  do { return try CategoryClassifier() } catch { fatalError("Dictionnaire embarqué illisible : \(error)") }
}()

@Test func allVectorFilesAreLoaded() throws {
  let vectors = try loadVectors()
  #expect(vectors.count >= 9)
  #expect(vectors.allSatisfy { $0.formatVersion == 1 && !$0.cases.isEmpty })
}

@Test(arguments: try loadVectors())
func vectorMatchesReference(_ vector: CategorizeVector) {
  for testCase in vector.cases {
    let got = classifier.classify(testCase.input)
    let want = testCase.expected
    #expect(got.normalized == want.normalized, "\(vector.id) « \(testCase.input) »")
    #expect(got.categoryId == want.categoryId, "\(vector.id) « \(testCase.input) »")
    #expect(got.matchedKeyword == want.matchedKeyword, "\(vector.id) « \(testCase.input) »")
    #expect(got.match.rawValue == want.match, "\(vector.id) « \(testCase.input) »")
  }
}

extension CategorizeVector: CustomTestStringConvertible {
  var testDescription: String { id }
}
