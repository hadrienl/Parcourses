import Foundation

/// Nature de la correspondance trouvée par le classifieur.
public enum MatchKind: String, Sendable, Codable {
  /// Modificateur prioritaire (« surgelé »…).
  case override
  /// Nom de produit ou expression du dictionnaire.
  case keyword
  /// Marque, retenue faute de nom de produit.
  case brand
  /// Trouvé après correction d'une faute de frappe (#98), faute de correspondance exacte.
  case fuzzy
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
  /// Vrai si le libellé contient « bio » ou « biologique », quelle que soit la catégorie (#28).
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
/// Correspondance exacte sur la forme normalisée ; faute de résultat, un mot inconnu à une faute
/// d'un mot-clé est corrigé avant de reclasser (#98). Valeur immuable et `Sendable` : on la
/// construit une fois et on la partage.
public struct CategoryClassifier: Sendable {
  /// Catégorie de repli.
  public static let otherCategoryId = "other"
  /// Mots retirés avant la recherche de mots-clés (#28), sous leur forme normalisée : « biologiques »
  /// arrive au singulier. Ils restent dans `normalized`. « AB » est exclu volontairement.
  public static let organicWords: Set<String> = ["bio", "biologique"]
  /// Longueur minimale d'un mot corrigé ; à cette longueur, seule une lettre manquante est admise.
  public static let typoMinLength = 5

  /// Normaliseur utilisé, exposé pour calculer `normalizedName` avec les mêmes règles.
  public let normalizer: LabelNormalizer
  private let keywords: [String: KeywordEntry]
  private let overrides: [String: String]
  private let maxWords: Int
  /// Tous les mots des clés et des modificateurs : un mot connu n'est jamais corrigé.
  private let vocabulary: Set<String>
  /// Mots-clés d'un seul mot, en octets ASCII, cibles des corrections.
  private let singleWords: [(key: [UInt8], entry: KeywordEntry)]

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
    vocabulary = Set(
      (Array(keywords.keys) + Array(overrides.keys)).flatMap { $0.split(separator: " ").map(String.init) })
    singleWords = keywords.values.filter { !$0.k.contains(" ") }.map { (Array($0.k.utf8), $0) }
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
    let tokens = words.filter { !Self.organicWords.contains($0) }
    let organic = tokens.count != words.count
    func result(_ category: String, _ key: String?, _ match: MatchKind) -> Classification {
      Classification(normalized: normalized, categoryId: category, matchedKeyword: key, match: match, organic: organic)
    }

    if let decision = decide(tokens) { return result(decision.category, decision.key, decision.match) }
    // 4. Repli : les mots inconnus corrigés, on reclasse. Un résultat exact n'est jamais changé.
    let corrected = tokens.map(correct)
    if corrected != tokens, let decision = decide(corrected) {
      return result(decision.category, decision.key, .fuzzy)
    }
    return result(Self.otherCategoryId, nil, .none)
  }

  /// Correspondance exacte : modificateurs, expressions, puis mots simples.
  private func decide(_ tokens: [String]) -> (category: String, key: String, match: MatchKind)? {
    // 1. Modificateurs : n-gramme le plus long, puis le plus à gauche.
    if let key = firstNGram(tokens, minWords: 1, where: { overrides[$0] != nil }), let category = overrides[key] {
      return (category, key, .override)
    }
    // 2. Expression multi-mots la plus longue, la plus à gauche.
    if let key = firstNGram(tokens, minWords: 2, where: { keywords[$0] != nil }), let entry = keywords[key] {
      return (entry.c, key, entry.brand == true ? .brand : .keyword)
    }
    // 3. Mot simple : premier nom de produit, sinon première marque.
    for brand in [false, true] {
      for token in tokens {
        if let entry = keywords[token], (entry.brand ?? false) == brand {
          return (entry.c, token, brand ? .brand : .keyword)
        }
      }
    }
    return nil
  }

  /// Correction d'un mot inconnu (#98) : mot-clé d'un seul mot, même initiale, à une opération
  /// près ; un mot de 5 lettres n'est corrigé que s'il lui manque une lettre. Plusieurs candidats :
  /// le premier dans l'ordre alphabétique s'ils ont tous la même catégorie, sinon aucun.
  private func correct(_ token: String) -> String {
    let bytes = Array(token.utf8)
    if bytes.count < Self.typoMinLength || vocabulary.contains(token)
      || bytes.contains(where: { (48...57).contains($0) })
    {
      return token
    }
    let short = bytes.count == Self.typoMinLength
    var best: (key: [UInt8], entry: KeywordEntry)?
    for candidate in singleWords {
      if candidate.key[0] != bytes[0] || (short && candidate.key.count != bytes.count + 1) { continue }
      if !Self.isOneEditAway(bytes, candidate.key) { continue }
      // Ordre de parcours sans effet : plus petite clé, et refus dès que deux catégories diffèrent.
      guard let current = best else {
        best = candidate
        continue
      }
      if current.entry.c != candidate.entry.c { return token }
      if candidate.key.lexicographicallyPrecedes(current.key) { best = candidate }
    }
    return best?.entry.k ?? token
  }

  /// Vrai si `b` s'obtient de `a` par une seule opération : insertion, suppression, substitution ou
  /// transposition de deux lettres voisines. Les chaînes sont en ASCII (sortie du normaliseur).
  static func isOneEditAway(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a == b || abs(a.count - b.count) > 1 { return false }
    var i = 0
    while i < a.count && i < b.count && a[i] == b[i] { i += 1 }
    if a.count > b.count { return a[(i + 1)...] == b[i...] }
    if a.count < b.count { return a[i...] == b[(i + 1)...] }
    if a[(i + 1)...] == b[(i + 1)...] { return true }
    return a[i] == b[i + 1] && a[i + 1] == b[i] && a[(i + 2)...] == b[(i + 2)...]
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
