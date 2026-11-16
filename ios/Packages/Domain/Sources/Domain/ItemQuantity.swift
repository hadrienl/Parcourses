import Foundation

/// Raccourcis d'unité du panneau de l'article (#110).
public enum QuantityUnit: String, CaseIterable, Sendable {
  case g, kg, l
}

/// Quantité d'un article (#110) : texte libre (« 2 », « 500 g », « 6x33cl », « un peu »). Le − / + agit sur le nombre
/// en tête, s'il y en a un ; le reste (unité, « x33cl ») est gardé tel quel. Mêmes règles qu'Android, vérifiées par
/// `shared/test-vectors/quantity/` (référence : `shared/reference/quantity.ts`).
public enum ItemQuantity {
  /// Longueur maximale, en points de code (`list_items.quantity`, `char_length <= 50`).
  public static let maxLength = 50
  private static let maxIntegerDigits = 6
  private static let maxFractionDigits = 3

  /// Nombre en tête, puis le reste. Chiffres ASCII seulement ; l'écart (blancs Unicode, espace insécable comprise)
  /// est gardé tel quel.
  private struct Parsed {
    var integer: String
    var separator: Character?
    var fraction: String
    var gap: String
    var rest: String

    var number: String { integer + (separator.map(String.init) ?? "") + fraction }
  }

  private static func parse(_ quantity: String) -> Parsed? {
    let scalars = Array(quantity.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
    var index = 0
    func digits() -> String {
      var out = ""
      while index < scalars.count, isASCIIDigit(scalars[index]) {
        out.unicodeScalars.append(scalars[index])
        index += 1
      }
      return out
    }
    let integer = digits()
    guard !integer.isEmpty else { return nil }
    var separator: Character?
    var fraction = ""
    // Séparateur décimal seulement s'il est suivi d'un chiffre : « 2, » garde la virgule dans le reste.
    if index + 1 < scalars.count, scalars[index] == "," || scalars[index] == ".", isASCIIDigit(scalars[index + 1]) {
      separator = Character(scalars[index])
      index += 1
      fraction = digits()
    }
    var gap = ""
    while index < scalars.count, scalars[index].properties.isWhitespace {
      gap.unicodeScalars.append(scalars[index])
      index += 1
    }
    var rest = ""
    rest.unicodeScalars.append(contentsOf: scalars[index...])
    guard integer.count <= maxIntegerDigits, fraction.count <= maxFractionDigits else { return nil }
    return Parsed(integer: integer, separator: separator, fraction: fraction, gap: gap, rest: rest)
  }

  private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
    ("0"..."9").contains(scalar)
  }

  /// Pas du − / + : 100 en grammes et millilitres, 10 en centilitres, 1 sinon.
  private static func step(_ rest: String) -> Int {
    switch rest.lowercased() {
    case "g", "ml": 100
    case "cl": 10
    default: 1
    }
  }

  private static func power(_ exponent: Int) -> Int {
    (0..<exponent).reduce(1) { value, _ in value * 10 }
  }

  /// Quantité après un appui sur + (`delta` 1) ou − (`delta` -1). Sans quantité, l'article compte pour un : + donne
  /// « 2 ». `nil` : bouton inactif (− à 1, quantité sans nombre en tête, nombre trop long, résultat de plus de 50
  /// points de code). Calcul en entiers à l'échelle des décimales tapées : même séparateur, même nombre de décimales.
  public static func stepQuantity(_ quantity: String?, delta: Int) -> String? {
    guard let quantity else { return delta > 0 ? "2" : nil }
    guard let parsed = parse(quantity), let whole = Int(parsed.integer) else { return nil }
    let decimals = parsed.fraction.count
    let factor = power(decimals)
    let value = whole * factor + (Int(parsed.fraction) ?? 0) + delta.signum() * step(parsed.rest) * factor
    guard value > 0, value < power(maxIntegerDigits + decimals) else { return nil }
    var number = String(value / factor)
    if decimals > 0 {
      let fraction = String(value % factor)
      number += String(parsed.separator ?? ",") + String(repeating: "0", count: decimals - fraction.count) + fraction
    }
    let result = parsed.rest.isEmpty ? number : number + parsed.gap + parsed.rest
    // Le résultat doit tenir dans la colonne (50 points de code) : sinon le bouton est inactif.
    return result.unicodeScalars.count > maxLength ? nil : result
  }

  /// Quantité après un raccourci d'unité. Sans quantité : une unité de base (« 100 g », « 1 kg », « 1 l »). Même unité
  /// déjà posée : retirée. Sinon le nombre garde son écriture et prend l'unité. `nil` : raccourci inactif.
  public static func setQuantityUnit(_ quantity: String?, unit: QuantityUnit) -> String? {
    guard let quantity else { return "\(step(unit.rawValue)) \(unit.rawValue)" }
    guard let parsed = parse(quantity) else { return nil }
    return parsed.rest.lowercased() == unit.rawValue ? parsed.number : "\(parsed.number) \(unit.rawValue)"
  }

  /// Raccourci sélectionné : l'unité qui fait tout le reste après le nombre (casse ignorée), sinon `nil`.
  public static func quantityUnit(_ quantity: String?) -> QuantityUnit? {
    guard let quantity, let parsed = parse(quantity) else { return nil }
    return QuantityUnit(rawValue: parsed.rest.lowercased())
  }

  /// Quantité du champ libre : blancs de bord retirés, blancs intérieurs réduits à une espace, coupée à 50 points de
  /// code, sans blanc final. Vide : pas de quantité.
  public static func quantityInput(_ text: String) -> String? {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    var cut = ""
    cut.unicodeScalars.append(contentsOf: collapsed.unicodeScalars.prefix(maxLength))
    while let last = cut.unicodeScalars.last, last.properties.isWhitespace { cut.unicodeScalars.removeLast() }
    return cut
  }

  /// Saisie rapide sur un article déjà dans la liste : une saisie qui porte une quantité met à jour le premier article
  /// non coché de même forme normalisée, dans l'ordre de la liste, au lieu d'ajouter un doublon. `nil` : ajout.
  public static func entryMergeTarget<ID>(
    normalizedName: String, quantity: String?, items: [(id: ID, normalizedName: String, checked: Bool)]
  ) -> ID? {
    guard quantity != nil else { return nil }
    return items.first { !$0.checked && $0.normalizedName == normalizedName }?.id
  }
}
