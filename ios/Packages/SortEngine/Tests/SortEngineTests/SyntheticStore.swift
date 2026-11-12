@testable import SortEngine

/// Magasin synthétique des mesures de performance (#30), identique à celui d'Android
/// (`SyntheticStore.kt`) : même générateur, même graphe, donc même ordre attendu.
enum SyntheticStore {
  static let items = 80
  static let storeProducts = 400
  static let edges = 3000
  static let categories = 20
  static let maxWeight: UInt64 = 5000

  /// Générateur congruentiel 64 bits (constantes de Knuth), reproduit tel quel en Kotlin.
  struct Lcg {
    var state: UInt64

    mutating func next(_ bound: UInt64) -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return (state >> 33) % bound
    }
  }

  static func productId(_ k: Int) -> String {
    let digits = String(k)
    return "p-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
  }

  /// `products` produits, `edges` arêtes distinctes, 80 articles sur les produits 0 à 79.
  static func input(products: Int) -> SortInput {
    var random = Lcg(state: 42)
    var seen = Set<Int>()
    var pairs: [(Int, Int)] = []
    while pairs.count < edges {
      let a = Int(random.next(UInt64(products)))
      let b = Int(random.next(UInt64(products)))
      guard a != b else { continue }
      let pair = (min(a, b), max(a, b))
      if seen.insert(pair.0 * products + pair.1).inserted { pairs.append(pair) }
    }
    let entries = (0..<categories).map {
      SnapshotEntry(productId: productId($0), weightQ: Int64(random.next(maxWeight)))
    }
    let snapshotEdges = pairs.map {
      SnapshotEdge(a: productId($0.0), b: productId($0.1), weightQ: Int64(random.next(maxWeight)))
    }
    return SortInput(
      categories: (0..<categories).map { SortCategory(id: "c-\($0)", rank: Int64($0)) },
      snapshot: SortSnapshot(confidenceQ: 900, entries: entries, edges: snapshotEdges),
      items: (0..<items).map {
        SortItem(id: "i-\($0)", productId: productId($0), categoryId: "c-\($0 % categories)", normalizedName: "n\($0)")
      },
      start: .entry, previousOrder: nil)
  }
}
