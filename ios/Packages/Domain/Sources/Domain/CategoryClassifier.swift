import Foundation

/// Nature de la correspondance trouvée par le classifieur.
public enum MatchKind: String, Sendable, Codable {
  /// Modificateur prioritaire (« surgelé »…).
  case override
  /// Nom de produit ou expression du dictionnaire.
  case keyword
  /// Marque, retenue faute de nom de produit.
  case brand
  /// Aucune correspondance : catégorie `other`.
  case none
}

/// Résultat de la classification d'un libellé.
public struct Classification: Sendable, Hashable {
  /// Forme normalisée du libellé (sans quantités ni mots vides, au singulier).
  public let normalized: String
  /// Catégorie retenue, `other` à défaut.
  public let categoryId: String
  /// Clé du dictionnaire qui a décidé, `nil` si aucune.
  public let matchedKeyword: String?
  /// Nature de la correspondance.
  public let match: MatchKind
  /// Vrai si le libellé contient le mot « bio », quelle que soit la catégorie (#28).
  public let organic: Bool

  public init(normalized: String, categoryId: String, matchedKeyword: String?, match: MatchKind, organic: Bool) {
    self.normalized = normalized
    self.categoryId = categoryId
    self.matchedKeyword = matchedKeyword
    self.match = match
    self.organic = organic
  }
}

/// Classifieur déterministe par mots-clés (#7 §2.3), identique à `shared/reference/classify.ts`.
///
/// Correspondance exacte sur la forme normalisée, sans distance d'édition. Valeur immuable
/// et `Sendable` : on la construit une fois et on la partage.
public struct CategoryClassifier: Sendable {
  /// Catégorie de repli.
  public static let otherCategoryId = "other"
  /// Mot retiré avant la recherche de mots-clés (#28). Il reste dans `normalized`.
  public static let organicWord = "bio"

  /// Normaliseur utilisé, exposé pour calculer `normalizedName` avec les mêmes règles.
  public let normalizer: LabelNormalizer
  private let keywords: [String: KeywordEntry]
  private let overrides: [String: String]
  private let maxWords: Int

  /// Classifieur sur un dictionnaire et des règles fournis (tests, autres langues).
  public init(dictionary: KeywordDictionary, rules: NormalizationRules) {
    normalizer = LabelNormalizer(rules: rules)
    var keywords: [String: KeywordEntry] = [:]
    var overrides: [String: String] = [:]
    var maxWords = 1
    // Dernière occurrence gagnante, comme Map.set dans la référence.
    for entry in dictionary.keywords {
      keywords[entry.k] = entry
      maxWords = max(maxWords, entry.k.split(separator: " ").count)
    }
    for entry in dictionary.overrides {
      overrides[entry.k] = entry.c
      maxWords = max(maxWords, entry.k.split(separator: " ").count)
    }
    self.keywords = keywords
    self.overrides = overrides
    self.maxWords = maxWords
  }

  /// Classifieur sur le dictionnaire français embarqué.
  public init() throws {
    self.init(
      dictionary: try CategoryResources.keywordDictionary(), rules: try CategoryResources.normalizationRules())
  }

  /// Classe un libellé saisi librement.
  public func classify(_ raw: String) -> Classification {
    let normalized = normalizer.normalize(raw)
    let words = normalized.split(separator: " ").map(String.init)
    let tokens = words.filter { $0 != Self.organicWord }
    let organic = tokens.count != words.count
    func result(_ category: String, _ key: String?, _ match: MatchKind) -> Classification {
      Classification(normalized: normalized, categoryId: category, matchedKeyword: key, match: match, organic: organic)
    }

    // 1. Modificateurs : n-gramme le plus long, puis le plus à gauche.
    if let key = firstNGram(tokens, minWords: 1, where: { overrides[$0] != nil }), let category = overrides[key] {
      return result(category, key, .override)
    }
    // 2. Expression multi-mots la plus longue, la plus à gauche.
    if let key = firstNGram(tokens, minWords: 2, where: { keywords[$0] != nil }), let entry = keywords[key] {
      return result(entry.c, key, entry.brand == true ? .brand : .keyword)
    }
    // 3. Mot simple : premier nom de produit, sinon première marque.
    for brand in [false, true] {
      for token in tokens {
        if let entry = keywords[token], (entry.brand ?? false) == brand {
          return result(entry.c, token, brand ? .brand : .keyword)
        }
      }
    }
    return result(Self.otherCategoryId, nil, .none)
  }

  /// Premier n-gramme accepté, du plus long au plus court puis de gauche à droite.
  private func firstNGram(_ tokens: [String], minWords: Int, where accept: (String) -> Bool) -> String? {
    var n = min(maxWords, tokens.count)
    while n >= minWords {
      for start in 0...(tokens.count - n) {
        let key = tokens[start..<(start + n)].joined(separator: " ")
        if accept(key) { return key }
      }
      n -= 1
    }
    return nil
  }
}
