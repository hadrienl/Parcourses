import Foundation
import Testing

@testable import Domain

@Test func moduleIsLinked() {
  #expect(Domain.version == "0.2.0")
}

@Test func dictionaryKeysAreAlreadyNormalized() throws {
  let dictionary = try CategoryResources.keywordDictionary()
  let normalizer = classifier.normalizer
  for entry in dictionary.keywords + dictionary.overrides {
    #expect(normalizer.normalize(entry.k) == entry.k, "\(entry.k)")
  }
}

@Test func dictionaryCategoriesExist() throws {
  let ids = Set(try CategoryResources.categories().map(\.id))
  let dictionary = try CategoryResources.keywordDictionary()
  #expect(ids.contains(CategoryClassifier.otherCategoryId))
  for entry in dictionary.keywords + dictionary.overrides {
    #expect(ids.contains(entry.c), "\(entry.k) → \(entry.c)")
  }
}

@Test func categoriesAreSortedByRank() throws {
  let categories = try CategoryResources.categories()
  #expect(categories.count == 20)
  #expect(categories.last?.id == "other")
  #expect(categories.map(\.rank) == categories.map(\.rank).sorted())
}

@Test func embeddedResourcesMatchSharedSources() throws {
  for name in ["categories.json", "normalization.json", "keywords.fr.json"] {
    let source = try Data(contentsOf: repositoryRoot.appendingPathComponent("shared/categories/\(name)"))
    let embedded = try Data(
      contentsOf: repositoryRoot.appendingPathComponent("ios/Packages/Domain/Sources/Domain/Resources/\(name)"))
    #expect(source == embedded, "\(name) : lancer ios/scripts/sync-categories.sh")
  }
}

@Test func normalizeTextIsLocaleIndependentAndScalarBased() {
  let normalizer = classifier.normalizer
  #expect(normalizer.normalizeText("  Œufs  BIO — Crème brûlée ") == "oeufs bio creme brulee")
  #expect(normalizer.normalizeText("Ißmaïl") == "issmail")
  #expect(normalizer.normalizeText("!!!") == "")
}

@Test func emptyLabelFallsBackToOther() {
  #expect(
    classifier.classify("") == Classification(normalized: "", categoryId: "other", matchedKeyword: nil, match: .none))
}
