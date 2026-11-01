import Foundation
import Testing

@testable import SortEngine

/// Vecteur partagé de `shared/test-vectors/sort/`, décodé tel quel.
struct SortVector: Decodable, Sendable, CustomTestStringConvertible {
  let id: String
  let input: SortInput
  let expected: SortOutput

  var testDescription: String { id }

  /// Dossier des vecteurs, lu dans le dépôt (jamais copié dans le paquet).
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()  // SortEngineTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // SortEngine
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // ios
    .deletingLastPathComponent()  // racine du dépôt
    .appending(path: "shared/test-vectors/sort")

  /// Tous les vecteurs, par nom de fichier.
  static let all: [SortVector] = {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { url in
        do {
          return try JSONDecoder().decode(SortVector.self, from: Data(contentsOf: url))
        } catch {
          fatalError("Vecteur illisible \(url.lastPathComponent) : \(error)")
        }
      }
  }()

  static func named(_ prefix: String) -> SortVector {
    guard let vector = all.first(where: { $0.id.hasPrefix(prefix) }) else {
      fatalError("Vecteur absent : \(prefix)")
    }
    return vector
  }
}

@Suite("Vecteurs partagés de tri")
struct SortVectorTests {
  @Test func allVectorsAreLoaded() {
    // 35 vecteurs au lot 9.2 : on échoue si le dossier est introuvable ou vidé.
    #expect(SortVector.all.count >= 35)
  }

  @Test("Même mode, même ordre et même coût que la référence", arguments: SortVector.all)
  func matchesReference(_ vector: SortVector) throws {
    #expect(try sortItems(vector.input) == vector.expected)
  }

  @Test("Le résultat ne dépend pas de l'ordre des entrées", arguments: SortVector.all)
  func independentOfInputOrder(_ vector: SortVector) throws {
    var generator = SplitMix64(seed: 0x5EED)
    for _ in 0..<3 {
      var input = vector.input
      input.items.shuffle(using: &generator)
      input.categories.shuffle(using: &generator)
      input.snapshot?.edges.shuffle(using: &generator)
      input.snapshot?.entries.shuffle(using: &generator)
      #expect(try sortItems(input) == vector.expected)
    }
  }

  @Test("Déterminisme et permutation des articles", arguments: SortVector.all)
  func deterministicPermutation(_ vector: SortVector) throws {
    let first = try sortItems(vector.input)
    #expect(try sortItems(vector.input) == first)
    #expect(first.order.sorted() == vector.input.items.map(\.id).sorted())
  }
}

/// Générateur pseudo-aléatoire à graine fixe, pour des mélanges reproductibles.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
