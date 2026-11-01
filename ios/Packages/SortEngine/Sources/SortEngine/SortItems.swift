// Point d'entrée du tri d'une liste sur l'appareil (#5 §2), portage fidèle de
// `shared/reference/sort.ts`. Règles de déterminisme (shared/README.md) :
// - uniquement des entiers `Int64`, INF = 2^40, addition saturée ;
// - identifiants ASCII [0-9a-z-] validés à l'entrée, comparés octet par octet ;
// - catégories réduites à leur indice ordinal ;
// - aucune itération sur un `Dictionary` ou un `Set` non trié.

/// Distance « infinie » : deux nœuds sans chemin connu dans le graphe.
public let sortInfinity: Int64 = 1 << 40

/// Trie les articles restants selon le trajet appris dans le magasin.
///
/// Fonction pure, déterministe et `nonisolated` : deux appels avec la même entrée donnent la
/// même sortie, quel que soit l'ordre des articles, arêtes, entrées et catégories fournis.
/// Pour 80 articles, le calcul prend quelques millisecondes ; l'app l'appelle hors du main
/// actor (`@concurrent`).
///
/// - Mode appris : si le graphe existe et que sa confiance atteint `CONF_THRESHOLD_Q`, plus
///   proche voisin puis 2-opt depuis `start`, avec hystérésis sur `previousOrder`.
/// - Repli : sinon, tri par (indice de catégorie, nom normalisé, identifiant).
///
/// - Throws: ``SortError`` si un identifiant n'est pas en `[0-9a-z-]+`, si un article ou une
///   catégorie est en double, ou si un poids sort de `0...2^53-1`.
public func sortItems(_ input: SortInput) throws(SortError) -> SortOutput {
  try validate(input)
  let ranks = RankResolver(input.categories)
  guard let snapshot = input.snapshot, snapshot.confidenceQ >= input.params.confThresholdQ else {
    return SortOutput(mode: .fallback, order: fallbackOrder(input.items, ranks), cost: nil)
  }
  // Ordre canonique : le résultat ne dépend pas de l'ordre fourni.
  let items = input.items.sorted { bytesPrecede($0.id, $1.id) }
  let ids = items.map(\.id)
  let matrix = DistanceMatrix(input: input, snapshot: snapshot, items: items, ranks: ranks)

  let optimized = twoOpt(
    matrix, path: nearestNeighbour(matrix, ids: ids), maxPasses: input.params.twoOptMaxPasses)
  var path = optimized
  // Un ordre précédent vide équivaut à nil : pas d'hystérésis.
  if let previousOrder = input.previousOrder, !previousOrder.isEmpty {
    let previous = previousPath(matrix, ids: ids, previous: previousOrder)
    let keep = 100 - input.params.reorderMinGainPct
    if matrix.pathCost(path) * 100 > matrix.pathCost(previous) * keep {
      path = previous
    }
  }
  return SortOutput(mode: .learned, order: path.dropFirst().map { ids[$0 - 1] }, cost: matrix.pathCost(path))
}

/// Repli : tri par (indice de catégorie, nom normalisé en octets UTF-8, identifiant).
func fallbackOrder(_ items: [SortItem], _ ranks: RankResolver) -> [String] {
  items.map { (rank: ranks.index(of: $0.categoryId), item: $0) }
    .sorted { x, y in
      if x.rank != y.rank { return x.rank < y.rank }
      let byName = compareBytes(x.item.normalizedName, y.item.normalizedName)
      if byName != 0 { return byName < 0 }
      return bytesPrecede(x.item.id, y.item.id)
    }
    .map(\.item.id)
}

/// Indice ordinal des catégories : liste triée par (rank, id) et numérotée 0..m-1. Une
/// catégorie absente ou inconnue prend l'indice de `other`, sinon m-1 (0 si la liste est vide).
struct RankResolver {
  private let indexById: [String: Int64]
  private let unknown: Int64

  init(_ categories: [SortCategory]) {
    let sorted = categories.sorted { x, y in
      x.rank != y.rank ? x.rank < y.rank : bytesPrecede(x.id, y.id)
    }
    var indexById: [String: Int64] = [:]
    for (offset, category) in sorted.enumerated() {
      indexById[category.id] = Int64(offset)
    }
    self.indexById = indexById
    self.unknown = indexById["other"] ?? Int64(max(0, sorted.count - 1))
  }

  func index(of categoryId: String?) -> Int64 {
    categoryId.flatMap { indexById[$0] } ?? unknown
  }
}
