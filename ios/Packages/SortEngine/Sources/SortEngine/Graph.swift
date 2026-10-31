// Graphe de voisinage d'un magasin et plus courts chemins entiers.

/// Addition saturée à ``sortInfinity``.
@inline(__always)
func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
  let sum = a + b
  return sum >= sortInfinity ? sortInfinity : sum
}

/// Coût d'une arête : plus le voisinage est observé, plus il est court.
func edgeCost(_ weightQ: Int64, _ params: SortParams) -> Int64 {
  params.costScale * 1000 / (1000 + weightQ)
}

/// Graphe à indices entiers. Les produits sont numérotés dans l'ordre de leurs octets : départager
/// la file de priorité par indice revient à la départager par `product_id`. L'entrée est un nœud
/// virtuel (indice `entry`) avec des arcs sortants uniquement : aucun chemin ne la traverse.
struct StoreGraph {
  /// Indice de chaque produit connu du graphe.
  let indexByProduct: [String: Int]
  /// Voisins de chaque nœud (entrée comprise), triés par indice : (voisin, coût minimal).
  let adjacency: [[(node: Int, cost: Int64)]]
  var entry: Int { adjacency.count - 1 }

  init(_ snapshot: SortSnapshot, _ params: SortParams) {
    var products = snapshot.edges.flatMap { [$0.a, $0.b] } + snapshot.entries.map(\.productId)
    products.sort(by: bytesPrecede)
    var indexByProduct: [String: Int] = [:]
    var count = 0
    for product in products where indexByProduct[product] == nil {
      indexByProduct[product] = count
      count += 1
    }
    // En cas de doublon (y compris (a,b) et (b,a)), on garde le coût minimal.
    var best = [[Int: Int64]](repeating: [:], count: count + 1)
    func put(_ from: Int, _ to: Int, _ cost: Int64) {
      if let old = best[from][to], old <= cost { return }
      best[from][to] = cost
    }
    for edge in snapshot.edges where edge.a != edge.b {
      let a = indexByProduct[edge.a]!
      let b = indexByProduct[edge.b]!
      let cost = edgeCost(edge.weightQ, params)
      put(a, b, cost)
      put(b, a, cost)
    }
    for entry in snapshot.entries {
      put(count, indexByProduct[entry.productId]!, edgeCost(entry.weightQ, params))
    }
    self.indexByProduct = indexByProduct
    self.adjacency = best.map { neighbours in
      neighbours.sorted { $0.key < $1.key }.map { (node: $0.key, cost: $0.value) }
    }
  }

  /// Dijkstra entier depuis `source`, file ordonnée par (distance, indice). Les nœuds non
  /// atteints restent à ``sortInfinity``.
  func distances(from source: Int) -> [Int64] {
    var dist = [Int64](repeating: sortInfinity, count: adjacency.count)
    var done = [Bool](repeating: false, count: adjacency.count)
    var heap = MinHeap()
    dist[source] = 0
    heap.push(Key(distance: 0, node: source))
    while let current = heap.pop() {
      if done[current.node] { continue }
      done[current.node] = true
      for (next, cost) in adjacency[current.node] where !done[next] {
        let candidate = saturatingAdd(current.distance, cost)
        if candidate < dist[next] {
          dist[next] = candidate
          heap.push(Key(distance: candidate, node: next))
        }
      }
    }
    return dist
  }
}

/// Clé de la file de priorité : (distance, indice du nœud).
struct Key {
  let distance: Int64
  let node: Int

  func precedes(_ other: Key) -> Bool {
    distance != other.distance ? distance < other.distance : node < other.node
  }
}

/// Tas binaire minimal, sans dépendance.
struct MinHeap {
  private var keys: [Key] = []

  mutating func push(_ key: Key) {
    keys.append(key)
    var child = keys.count - 1
    while child > 0 {
      let parent = (child - 1) / 2
      guard keys[child].precedes(keys[parent]) else { break }
      keys.swapAt(child, parent)
      child = parent
    }
  }

  mutating func pop() -> Key? {
    guard !keys.isEmpty else { return nil }
    keys.swapAt(0, keys.count - 1)
    let top = keys.removeLast()
    var parent = 0
    while true {
      let left = 2 * parent + 1
      let right = left + 1
      var smallest = parent
      if left < keys.count, keys[left].precedes(keys[smallest]) { smallest = left }
      if right < keys.count, keys[right].precedes(keys[smallest]) { smallest = right }
      if smallest == parent { return top }
      keys.swapAt(parent, smallest)
      parent = smallest
    }
  }
}
