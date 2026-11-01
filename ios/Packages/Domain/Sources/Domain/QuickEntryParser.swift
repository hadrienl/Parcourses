import Foundation

/// Résultat de l'analyse d'une saisie rapide.
public struct QuickEntry: Sendable, Hashable {
  /// Quantité en texte libre (`2`, `500 g`), `nil` si aucune.
  public let quantity: String?
  /// Libellé tel que saisi, sans la quantité.
  public let label: String

  public init(quantity: String?, label: String) {
    self.quantity = quantity
    self.label = label
  }
}

/// Sépare quantité et libellé dans une saisie rapide (#9 §9) : « 2 laits demi-écrémé ».
///
/// Formes reconnues : `2 lait`, `1,5 kg de pommes`, `500g farine`, `2,5kg pommes`, `6x33cl bière`,
/// `lait x2`, `x2 lait`. Un nombre seul de plus de 3 chiffres reste un libellé (`1664 bière`).
/// Limite connue : `3 Suisses` donne la quantité 3.
/// Une saisie réduite à une quantité reste un libellé : on ne perd jamais ce qui a été tapé.
public struct QuickEntryParser: Sendable {
  private static let maxBareDigits = 3
  private let units: Set<String>
  private let normalizer: LabelNormalizer

  public init(rules: NormalizationRules) {
    units = rules.units
    normalizer = LabelNormalizer(rules: rules)
  }

  /// Analyseur sur les règles françaises embarquées.
  public init() throws {
    self.init(rules: try CategoryResources.normalizationRules())
  }

  /// Analyse une saisie. Le libellé est vide seulement si la saisie l'est.
  public func parse(_ raw: String) -> QuickEntry {
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    let trimmed = tokens.joined(separator: " ")
    guard let first = tokens.first else { return QuickEntry(quantity: nil, label: "") }

    guard let (quantity, rest) = leadingQuantity(tokens) ?? Self.trailingMultiplier(tokens) else {
      return QuickEntry(quantity: nil, label: trimmed)
    }
    let label = Self.droppingPartitive(rest).joined(separator: " ")
    return label.isEmpty ? QuickEntry(quantity: nil, label: trimmed) : QuickEntry(quantity: quantity, label: label)
  }

  /// Quantité en tête : nombre et unité, forme collée, ou `x2`.
  private func leadingQuantity(_ tokens: [String]) -> (String, [String])? {
    guard let first = tokens.first else { return nil }
    let rest = Array(tokens.dropFirst())
    if Self.isNumber(first) {
      if let next = rest.first, units.contains(normalizer.normalizeText(next)) {
        // « 2 x lait » : le « x » n'apporte rien à la quantité affichée.
        let quantity = normalizer.normalizeText(next) == "x" ? first : "\(first) \(next)"
        return (quantity, Array(rest.dropFirst()))
      }
      // Au-delà de 3 chiffres, un nombre seul est un nom (« 1664 bière »).
      return first.count { $0.isASCIIDigit } <= Self.maxBareDigits ? (first, rest) : nil
    }
    if isGluedQuantity(first) { return (first, rest) }
    if Self.isMultiplier(first) { return (String(first.dropFirst()), rest) }
    return nil
  }

  /// `lait x2`.
  private static func trailingMultiplier(_ tokens: [String]) -> (String, [String])? {
    guard tokens.count > 1, let last = tokens.last, isMultiplier(last) else { return nil }
    return (String(last.dropFirst()), Array(tokens.dropLast()))
  }

  /// Retire « de », « d' » ou « d’ » placé juste après la quantité.
  private static func droppingPartitive(_ tokens: [String]) -> [String] {
    guard var first = tokens.first else { return tokens }
    let lowered = first.lowercased()
    if lowered == "de" || lowered == "d'" || lowered == "d’" { return Array(tokens.dropFirst()) }
    if lowered.hasPrefix("d'") || lowered.hasPrefix("d’") {
      first.removeFirst(2)
      return [first] + tokens.dropFirst()
    }
    return tokens
  }

  /// `2`, `1,5`, `0.5`.
  private static func isNumber(_ token: String) -> Bool {
    let parts = token.split(separator: /[.,]/, omittingEmptySubsequences: false)
    return parts.count <= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
  }

  /// `x2`.
  private static func isMultiplier(_ token: String) -> Bool {
    let lowered = token.lowercased()
    return lowered.hasPrefix("x") && lowered.count > 1 && lowered.dropFirst().allSatisfy(\.isASCIIDigit)
  }

  /// `500g`, `2kg`, `2,5kg`, `1.5l`, `2x`, `6x33cl`.
  private func isGluedQuantity(_ token: String) -> Bool {
    let lowered = token.lowercased()
    let number = lowered.prefix { $0.isASCIIDigit || $0 == "," || $0 == "." }
    let suffix = lowered.dropFirst(number.count)
    if Self.isNumber(String(number)), units.contains(String(suffix)) { return true }
    let digits = lowered.prefix(while: \.isASCIIDigit)
    guard !digits.isEmpty, digits.count == number.count else { return false }
    guard suffix.first == "x" else { return false }
    let afterX = suffix.dropFirst()
    let innerDigits = afterX.prefix(while: \.isASCIIDigit)
    guard !innerDigits.isEmpty else { return false }
    return innerDigits.count == afterX.count || units.contains(String(afterX.dropFirst(innerDigits.count)))
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
