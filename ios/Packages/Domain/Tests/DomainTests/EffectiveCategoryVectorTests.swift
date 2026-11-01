import Foundation
import Testing

@testable import Domain

/// Vecteur partagé de `shared/test-vectors/effective-category/`.
struct EffectiveCategoryVector: Decodable, Sendable {
  struct Case: Decodable, Sendable {
    struct Input: Decodable, Sendable {
      let categoryId: String
      let organic: Bool
      let storeOrganicAisle: Bool

      enum CodingKeys: String, CodingKey {
        case organic
        case categoryId = "category_id"
        case storeOrganicAisle = "store_organic_aisle"
      }
    }

    struct Expected: Decodable, Sendable {
      let effectiveCategory: String

      enum CodingKeys: String, CodingKey {
        case effectiveCategory = "effective_category"
      }
    }

    let label: String?
    let input: Input
    let expected: Expected
  }

  let id: String
  let cases: [Case]
}

extension EffectiveCategoryVector: CustomTestStringConvertible {
  var testDescription: String { id }
}

func loadEffectiveCategoryVectors() throws -> [EffectiveCategoryVector] {
  let directory = repositoryRoot.appendingPathComponent("shared/test-vectors/effective-category")
  return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { try JSONDecoder().decode(EffectiveCategoryVector.self, from: Data(contentsOf: $0)) }
}

@Test func effectiveCategoryVectorsAreLoaded() throws {
  let vectors = try loadEffectiveCategoryVectors()
  #expect(vectors.count >= 2)
  #expect(vectors.allSatisfy { !$0.cases.isEmpty })
}

@Test(arguments: try loadEffectiveCategoryVectors())
func effectiveCategoryMatchesReference(_ vector: EffectiveCategoryVector) {
  for testCase in vector.cases {
    let input = testCase.input
    if let label = testCase.label {
      let classification = classifier.classify(label)
      #expect(classification.categoryId == input.categoryId, "\(vector.id) « \(label) »")
      #expect(classification.organic == input.organic, "\(vector.id) « \(label) »")
    }
    let got = effectiveCategory(
      categoryId: input.categoryId, organic: input.organic, storeOrganicAisle: input.storeOrganicAisle)
    #expect(got == testCase.expected.effectiveCategory, "\(vector.id) \(input)")
  }
}
