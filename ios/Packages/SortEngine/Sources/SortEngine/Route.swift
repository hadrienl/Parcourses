// Construction du trajet : plus proche voisin, 2-opt et chemin de l'ordre précédent.
// `ids[k - 1]` est l'identifiant de l'article d'indice `k` dans la matrice.

/// Plus proche voisin depuis le nœud 0 ; à égalité, plus petit identifiant (donc plus petit
/// indice, les articles étant triés par identifiant).
func nearestNeighbour(_ matrix: DistanceMatrix, ids: [String]) -> [Int] {
  var used = [Bool](repeating: false, count: matrix.size)
  var path = [0]
  var current = 0
  for _ in 1..<max(matrix.size, 1) {
    var best = -1
    for j in 1..<matrix.size where !used[j] {
      if best == -1 || matrix[current, j] < matrix[current, best]
        || (matrix[current, j] == matrix[current, best] && bytesPrecede(ids[j - 1], ids[best - 1]))
      {
        best = j
      }
    }
    used[best] = true
    path.append(best)
    current = best
  }
  return path
}

/// 2-opt sur chemin ouvert : première amélioration, boucles `i = 1..n-2`, `k = i+1..n-1`,
/// départ fixe, au plus `maxPasses` passes.
func twoOpt(_ matrix: DistanceMatrix, path start: [Int], maxPasses: Int64) -> [Int] {
  var path = start
  let count = path.count
  guard count >= 3 else { return path }
  var pass: Int64 = 0
  while pass < maxPasses {
    pass += 1
    var improved = false
    for i in 1...(count - 2) {
      for k in (i + 1)...(count - 1) {
        let hasNext = k + 1 < count
        let added = matrix[path[i - 1], path[k]] + (hasNext ? matrix[path[i], path[k + 1]] : 0)
        let removed = matrix[path[i - 1], path[i]] + (hasNext ? matrix[path[k], path[k + 1]] : 0)
        if added - removed < 0 {
          path[i...k].reverse()
          improved = true
        }
      }
    }
    if !improved { break }
  }
  return path
}

/// Ordre précédent restreint aux articles présents (premières occurrences, identifiants inconnus
/// ignorés) ; les nouveaux articles, par identifiant croissant, sont insérés un à un à la
/// position de moindre surcoût (à égalité, la plus en tête ; la fin compte comme position).
func previousPath(_ matrix: DistanceMatrix, ids: [String], previous: [String]) -> [Int] {
  var indexById: [String: Int] = [:]
  for (offset, id) in ids.enumerated() { indexById[id] = offset + 1 }
  var seen = [Bool](repeating: false, count: matrix.size)
  var path = [0]
  for id in previous {
    guard let j = indexById[id], !seen[j] else { continue }
    seen[j] = true
    path.append(j)
  }
  // Les indices croissants suivent déjà l'ordre des identifiants.
  for j in 1..<max(matrix.size, 1) where !seen[j] {
    var bestPosition = -1
    var bestIncrease: Int64 = 0
    for position in 1...path.count {
      let before = path[position - 1]
      let increase: Int64
      if position < path.count {
        let after = path[position]
        increase = matrix[before, j] + matrix[j, after] - matrix[before, after]
      } else {
        increase = matrix[before, j]
      }
      if bestPosition == -1 || increase < bestIncrease {
        bestPosition = position
        bestIncrease = increase
      }
    }
    path.insert(j, at: bestPosition)
  }
  return path
}
