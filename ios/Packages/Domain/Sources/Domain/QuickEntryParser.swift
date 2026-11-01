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
/// Formes reconnues : `2 lait`, `1,5 kg de pommes`, `500g farine`, `6x33cl bière`, `lait x2`.
/// Une saisie réduite à une quantité reste un libellé : on ne perd jamais ce qui a été tapé.
public struct QuickEntryParser: Sendable {
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

    var quantity: String?
    var rest = Array(tokens.dropFirst())
    if Self.isNumber(first) {
      quantity = first
      if let next = rest.first, units.contains(normalizer.normalizeText(next)) {
        // « 2 x lait » : le « x » n'apporte rien à la quantité affichée.
        if normalizer.normalizeText(next) != "x" { quantity = "\(first) \(next)" }
        rest.removeFirst()
      }
    } else if isGluedQuantity(first) {
      quantity = first
    } else if tokens.count > 1, let last = tokens.last, Self.isTrailingMultiplier(last) {
      quantity = String(last.dropFirst())
      rest = Array(tokens.dropLast())
    } else {
      return QuickEntry(quantity: nil, label: trimmed)
    }

    let label = Self.droppingPartitive(rest).joined(separator: " ")
    return label.isEmpty ? QuickEntry(quantity: nil, label: trimmed) : QuickEntry(quantity: quantity, label: label)
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

  /// `x2` en fin de saisie.
  private static func isTrailingMultiplier(_ token: String) -> Bool {
    let lowered = token.lowercased()
    return lowered.hasPrefix("x") && lowered.count > 1 && lowered.dropFirst().allSatisfy(\.isASCIIDigit)
  }

  /// `500g`, `2kg`, `2x`, `6x33cl`.
  private func isGluedQuantity(_ token: String) -> Bool {
    let lowered = token.lowercased()
    let digits = lowered.prefix(while: \.isASCIIDigit)
    guard !digits.isEmpty else { return false }
    let suffix = lowered.dropFirst(digits.count)
    if units.contains(String(suffix)) { return true }
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
