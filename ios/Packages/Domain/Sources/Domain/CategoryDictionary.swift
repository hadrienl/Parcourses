import Foundation

/// Une catégorie de rayon (#7 §1). `rank` ne sert qu'à ordonner.
public struct ItemCategory: Sendable, Hashable, Codable {
  /// Identifiant stable, ASCII `[0-9a-z-]` (`produce`, `savory-grocery`…).
  public let id: String
  /// Clé d'ordre générique du rayon (10, 20… 999 pour `other`).
  public let rank: Int
  /// Libellé français affiché.
  public let labelFr: String

  public init(id: String, rank: Int, labelFr: String) {
    self.id = id
    self.rank = rank
    self.labelFr = labelFr
  }

  enum CodingKeys: String, CodingKey {
    case id, rank
    case labelFr = "label_fr"
  }
}

/// Règles de normalisation (`normalization.json`).
public struct NormalizationRules: Sendable, Codable {
  public let ligatures: [String: String]
  public let units: Set<String>
  public let stopwords: Set<String>
  public let pluralAl: Set<String>
  public let pluralExceptions: Set<String>

  enum CodingKeys: String, CodingKey {
    case ligatures, units, stopwords
    case pluralAl = "plural_al"
    case pluralExceptions = "plural_exceptions"
  }
}

/// Entrée du dictionnaire : clé déjà normalisée, catégorie, marque éventuelle.
public struct KeywordEntry: Sendable, Codable, Hashable {
  /// Forme normalisée (`normalize(k) == k`).
  public let k: String
  /// Identifiant de catégorie.
  public let c: String
  /// Vrai pour une marque, qui ne l'emporte jamais sur un nom de produit.
  public let brand: Bool?
}

/// Dictionnaire de mots-clés (`keywords.fr.json`).
public struct KeywordDictionary: Sendable, Codable {
  public let version: Int
  public let locale: String
  public let keywords: [KeywordEntry]
  /// Modificateurs prioritaires (« surgelé »…).
  public let overrides: [KeywordEntry]
}

/// Erreurs de chargement des ressources embarquées.
public enum CategoryResourceError: Error, Sendable {
  case missingResource(String)
}

/// Accès aux fichiers de `shared/categories/` embarqués dans le paquet.
public enum CategoryResources {
  private struct CategoriesFile: Decodable {
    let version: Int
    let categories: [ItemCategory]
  }

  // Lecture et décodage une seule fois par processus ; une erreur est mémorisée et relancée.
  private static let cachedCategories = Result<CategoriesFile, any Error> {
    let file: CategoriesFile = try decode("categories")
    return CategoriesFile(
      version: file.version,
      categories: file.categories.sorted { ($0.rank, $0.id) < ($1.rank, $1.id) })
  }
  private static let cachedRules = Result<NormalizationRules, any Error> { try decode("normalization") }
  private static let cachedKeywords = Result<KeywordDictionary, any Error> { try decode("keywords.fr") }

  /// Les 20 catégories, triées par `(rank, id)`. Lues une seule fois, puis servies depuis le cache.
  public static func categories() throws -> [ItemCategory] {
    try cachedCategories.get().categories
  }

  /// Version de `categories.json` : l'amorçage local n'est rejoué que si elle augmente.
  public static func categoriesVersion() throws -> Int {
    try cachedCategories.get().version
  }

  /// Règles de normalisation françaises. Lues une seule fois, puis servies depuis le cache.
  public static func normalizationRules() throws -> NormalizationRules {
    try cachedRules.get()
  }

  /// Dictionnaire de mots-clés français. Lu une seule fois, puis servi depuis le cache.
  public static func keywordDictionary() throws -> KeywordDictionary {
    try cachedKeywords.get()
  }

  private static func decode<T: Decodable>(_ name: String) throws -> T {
    guard
      let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
    else { throw CategoryResourceError.missingResource(name) }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
  }
}
