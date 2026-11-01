import Foundation

/// Normalisation des libellés (#7 §2.1), identique à `shared/reference/normalize.ts`.
///
/// Le texte est traité scalaire par scalaire (`unicodeScalars`), jamais par `Character`,
/// pour que lettre et accent restent séparables après la décomposition NFD.
public struct LabelNormalizer: Sendable {
  private let rules: NormalizationRules
  /// Ligatures triées par clé, pour un résultat indépendant de l'ordre du dictionnaire.
  private let ligatures: [(String, String)]

  /// Normaliseur sur les règles fournies.
  public init(rules: NormalizationRules) {
    self.rules = rules
    self.ligatures = rules.ligatures.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
      .map { ($0.key, $0.value) }
  }

  /// Normaliseur sur les règles françaises embarquées.
  public init() throws {
    self.init(rules: try CategoryResources.normalizationRules())
  }

  /// Forme « texte » : minuscules, ligatures, sans diacritiques, `[a-z0-9]` séparés par une espace.
  /// C'est le `normalizedName` utilisé par le tri de repli.
  public func normalizeText(_ raw: String) -> String {
    // Minuscules sans dépendre de la locale de l'appareil.
    // `.literal` plus bas : sans cette option, la comparaison par graphème ignore « œ » suivi d'un accent.
    var text = raw.lowercased(with: Locale(identifier: "en_US_POSIX"))
    for (from, to) in ligatures { text = text.replacingOccurrences(of: from, with: to, options: .literal) }
    var output = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
      // Marques diacritiques combinantes U+0300 à U+036F : supprimées sans séparer les mots.
      if (0x0300...0x036F).contains(scalar.value) { continue }
      if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
        if pendingSpace && !output.isEmpty { output.append(" ") }
        pendingSpace = false
        output.append(scalar)
      } else {
        pendingSpace = true
      }
    }
    return String(output)
  }

  /// Forme de comparaison avec le dictionnaire : forme texte sans quantités, unités
  /// ni mots vides, chaque mot au singulier.
  public func normalize(_ raw: String) -> String {
    normalizeText(raw)
      .split(separator: " ")
      .map(String.init)
      .filter { !rules.stopwords.contains($0) && !isQuantity($0) }
      .map(singularize)
      .joined(separator: " ")
  }

  /// Singulier par règles simples ; les exceptions sont prioritaires.
  public func singularize(_ token: String) -> String {
    if rules.pluralExceptions.contains(token) { return token }
    if rules.pluralAl.contains(token) { return String(token.dropLast(3)) + "al" }
    if token.hasSuffix("eux") || token.hasSuffix("aux") || token.hasSuffix("oux") {
      return String(token.dropLast())
    }
    if token.hasSuffix("s") && token.unicodeScalars.count > 3 { return String(token.dropLast()) }
    return token
  }

  /// Vrai pour un nombre, une unité, un nombre collé à une unité (`2kg`) ou `x6`, `6x33cl`.
  private func isQuantity(_ token: String) -> Bool {
    if rules.units.contains(token) { return true }
    let scalars = Array(token.unicodeScalars)
    let isDigit = { (s: Unicode.Scalar) in ("0"..."9").contains(s) }
    let isLetter = { (s: Unicode.Scalar) in ("a"..."z").contains(s) }
    // ^[0-9]*x[0-9]+[a-z]*$
    var i = 0
    while i < scalars.count && isDigit(scalars[i]) { i += 1 }
    if i < scalars.count && scalars[i] == "x" {
      var j = i + 1
      let digitsStart = j
      while j < scalars.count && isDigit(scalars[j]) { j += 1 }
      if j > digitsStart && scalars[j...].allSatisfy(isLetter) { return true }
    }
    // ^[0-9]+([a-z]*)$ avec suffixe vide ou unité connue.
    guard i > 0, scalars[i...].allSatisfy(isLetter) else { return false }
    let suffix = String(String.UnicodeScalarView(scalars[i...]))
    return suffix.isEmpty || rules.units.contains(suffix)
  }
}
