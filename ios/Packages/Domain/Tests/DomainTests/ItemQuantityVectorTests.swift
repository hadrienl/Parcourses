import Foundation
import Testing

@testable import Domain

/// Vecteurs partagés de `shared/test-vectors/quantity/` (#110), lus sans copie. Chaque cas est relu en JSON brut : les
/// entrées diffèrent d'une fonction à l'autre.
struct ItemQuantityVector: Sendable, CustomTestStringConvertible {
  let id: String
  let function: String
  let cases: [[String: JSONValue]]

  var testDescription: String { id }
}

/// Valeur JSON minimale : chaînes, nombres, booléens, `null`, tableaux et objets.
indirect enum JSONValue: Decodable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  var string: String? {
    if case .string(let value) = self { value } else { nil }
  }

  subscript(key: String) -> JSONValue {
    if case .object(let object) = self { object[key] ?? .null } else { .null }
  }
}

private struct RawVector: Decodable {
  let id: String
  let function: String
  let cases: [[String: JSONValue]]
}

func loadItemQuantityVectors() throws -> [ItemQuantityVector] {
  let directory = repositoryRoot.appendingPathComponent("shared/test-vectors/quantity")
  return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map { url in
      let raw = try JSONDecoder().decode(RawVector.self, from: Data(contentsOf: url))
      return ItemQuantityVector(id: raw.id, function: raw.function, cases: raw.cases)
    }
}

/// Résultat d'une fonction de `ItemQuantity` sur l'entrée d'un cas ; `nil` : fonction inconnue.
private func run(_ function: String, _ input: JSONValue) -> JSONValue? {
  let wrap: (String?) -> JSONValue = { $0.map(JSONValue.string) ?? .null }
  switch function {
  case "stepQuantity":
    guard case .number(let delta) = input["delta"] else { return nil }
    return wrap(ItemQuantity.stepQuantity(input["quantity"].string, delta: Int(delta)))
  case "setQuantityUnit":
    guard let unit = input["unit"].string.flatMap(QuantityUnit.init(rawValue:)) else { return nil }
    return wrap(ItemQuantity.setQuantityUnit(input["quantity"].string, unit: unit))
  case "quantityUnit":
    return wrap(ItemQuantity.quantityUnit(input["quantity"].string)?.rawValue)
  case "quantityInput":
    return wrap(ItemQuantity.quantityInput(input["text"].string ?? ""))
  case "entryMergeTarget":
    guard case .array(let items) = input["items"], let name = input["entry"]["normalizedName"].string else {
      return nil
    }
    let candidates = items.map { item in
      (
        id: item["id"].string ?? "", normalizedName: item["normalizedName"].string ?? "",
        checked: item["checked"] == .bool(true)
      )
    }
    return wrap(
      ItemQuantity.entryMergeTarget(
        normalizedName: name, quantity: input["entry"]["quantity"].string, items: candidates))
  default:
    return nil
  }
}

@Test func itemQuantityVectorsCoverEveryFunction() throws {
  let functions = Set(try loadItemQuantityVectors().map(\.function))
  #expect(functions == ["stepQuantity", "setQuantityUnit", "quantityUnit", "quantityInput", "entryMergeTarget"])
}

@Test(arguments: try loadItemQuantityVectors())
func itemQuantityMatchesReference(_ vector: ItemQuantityVector) {
  #expect(!vector.cases.isEmpty)
  for testCase in vector.cases {
    let input = testCase["input"] ?? .null
    let name = testCase["name"]?.string ?? "?"
    let got = run(vector.function, input)
    #expect(got != nil, "\(vector.id) : fonction inconnue \(vector.function)")
    #expect(got == testCase["expected"] ?? .null, "\(vector.id) « \(name) »")
  }
}
