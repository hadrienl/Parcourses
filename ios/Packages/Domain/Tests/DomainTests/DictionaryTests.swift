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

@Test func organicCategoryReceivesNoKeyword() throws {
  let dictionary = try CategoryResources.keywordDictionary()
  #expect(try CategoryResources.categories().contains { $0.id == organicCategoryId })
  for entry in dictionary.keywords + dictionary.overrides {
    #expect(entry.c != organicCategoryId, "\(entry.k)")
    let words = entry.k.split(separator: " ")
    #expect(!words.contains { CategoryClassifier.organicWords.contains(String($0)) }, "\(entry.k)")
  }
}

@Test func categoriesAreSortedByRank() throws {
  let categories = try CategoryResources.categories()
  #expect(categories.count == 21)
  #expect(categories.last?.id == "other")
  #expect(categories.map(\.rank) == categories.map(\.rank).sorted())
}

@Test func normalizeTextIsLocaleIndependentAndScalarBased() {
  let normalizer = classifier.normalizer
  #expect(normalizer.normalizeText("  Œufs  BIO — Crème brûlée ") == "oeufs bio creme brulee")
  #expect(normalizer.normalizeText("Ißmaïl") == "issmail")
  #expect(normalizer.normalizeText("!!!") == "")
}

@Test func emptyLabelFallsBackToOther() {
  #expect(
    classifier.classify("")
      == Classification(normalized: "", categoryId: "other", matchedKeyword: nil, match: .none, organic: false))
}

@Test func categoriesVersionIsExposed() throws {
  #expect(try CategoryResources.categoriesVersion() >= 1)
}
