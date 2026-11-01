// Matrice des distances entre le départ (indice 0) et les articles (indices 1..n), à plat.

struct DistanceMatrix {
  /// Nombre de nœuds, départ compris.
  let size: Int
  private var values: [Int64]

  subscript(_ i: Int, _ j: Int) -> Int64 {
    values[i * size + j]
  }

  /// `d(x,y) = min(graph_dist, cat_cost)`. La colonne 0 vaut 0 : on ne revient jamais au départ.
  init(input: SortInput, snapshot: SortSnapshot, items: [SortItem], ranks: RankResolver) {
    let params = input.params
    let graph = StoreGraph(snapshot, params)
    // Nœud de chaque point : produit (texte, pour l'égalité), indice dans le graphe, catégorie.
    // Le départ n'a pas de catégorie : il se comporte comme l'entrée pour le repli.
    var products: [String?] = []
    var graphNodes: [Int?] = []
    var categoryRanks: [Int64?] = [nil]
    switch input.start {
    case .entry:
      products.append(nil)
      graphNodes.append(graph.entry)
    case .product(let productId):
      products.append(productId)
      graphNodes.append(graph.indexByProduct[productId])
    }
    for item in items {
      products.append(item.productId)
      graphNodes.append(item.productId.flatMap { graph.indexByProduct[$0] })
      categoryRanks.append(ranks.index(of: item.categoryId))
    }

    // Un Dijkstra par nœud source distinct, mis en cache.
    var cache = [[Int64]?](repeating: nil, count: graph.adjacency.count)
    let size = items.count + 1
    var values = [Int64](repeating: 0, count: size * size)
    for i in 0..<size {
      let source = graphNodes[i]
      var row: [Int64]?
      if let source {
        if cache[source] == nil { cache[source] = graph.distances(from: source) }
        row = cache[source]
      }
      // Seul l'article qui a un produit peut se trouver dans le graphe (l'entrée n'en a pas,
      // mais elle a ses arcs sortants).
      let hasProduct = i == 0 ? true : products[i] != nil
      for j in 1..<max(size, 1) where i != j {
        let catCost: Int64
        if let a = categoryRanks[i] {
          catCost = params.unknownBase + params.catStep * abs(a - categoryRanks[j]!)
        } else {
          catCost = params.unknownBase + params.catStep * categoryRanks[j]!
        }
        var graphDist = sortInfinity
        if hasProduct, let product = products[j] {
          if products[i] == product {
            graphDist = 0
          } else if let row, let target = graphNodes[j] {
            graphDist = row[target]
          }
        }
        values[i * size + j] = min(graphDist, catCost)
      }
    }
    self.size = size
    self.values = values
  }

  /// Coût d'un chemin ouvert (indices de la matrice, départ compris).
  func pathCost(_ path: [Int]) -> Int64 {
    var cost: Int64 = 0
    for (from, to) in zip(path, path.dropFirst()) {
      cost = saturatingAdd(cost, self[from, to])
    }
    return cost
  }
}
