package fr.parcourses.core.sorting

// Construction du trajet sur la matrice des distances : plus proche voisin, 2-opt et
// chemin précédent pour l'hystérésis. Le nœud 0 est le départ ; `ids[0]` est vide.

/** Coût d'un chemin ouvert (indices de la matrice, départ compris). */
internal fun pathCost(
    d: DistanceMatrix,
    path: IntArray,
): Long {
    var c = 0L
    for (i in 0 until path.size - 1) c = satAdd(c, d[path[i], path[i + 1]])
    return c
}

/** Plus proche voisin depuis le nœud 0 ; à égalité, plus petit identifiant d'article. */
internal fun nearestNeighbour(
    d: DistanceMatrix,
    ids: List<String>,
): IntArray {
    val n = d.size
    val used = BooleanArray(n)
    val path = IntArray(n)
    used[0] = true
    var cur = 0
    for (step in 1 until n) {
        var best = -1
        for (j in 1 until n) {
            if (used[j]) continue
            if (best == -1 || isCloser(d, cur, ids, j, best)) best = j
        }
        used[best] = true
        path[step] = best
        cur = best
    }
    return path
}

/** Vrai si `j` est plus proche que `best` depuis `cur` ; à égalité, plus petit id. */
private fun isCloser(
    d: DistanceMatrix,
    cur: Int,
    ids: List<String>,
    j: Int,
    best: Int,
): Boolean = d[cur, j] < d[cur, best] || (d[cur, j] == d[cur, best] && compareIds(ids[j], ids[best]) < 0)

/** 2-opt sur chemin ouvert, première amélioration, ordre de boucle imposé, départ fixe. */
internal fun twoOpt(
    d: DistanceMatrix,
    path: IntArray,
    maxPasses: Long,
): IntArray {
    val p = path.copyOf()
    val n = p.size
    var pass = 0L
    while (pass < maxPasses) {
        var improved = false
        for (i in 1..n - 2) {
            for (k in i + 1..n - 1) {
                if (twoOptDelta(d, p, i, k) < 0) {
                    p.reverse(i, k + 1)
                    improved = true
                }
            }
        }
        if (!improved) break
        pass++
    }
    return p
}

/** Variation de coût si l'on inverse le segment de i à k (la fin de chemin n'a pas d'arc sortant). */
private fun twoOptDelta(
    d: DistanceMatrix,
    p: IntArray,
    i: Int,
    k: Int,
): Long {
    val hasNext = k + 1 < p.size
    val added = d[p[i - 1], p[k]] + (if (hasNext) d[p[i], p[k + 1]] else 0L)
    val removed = d[p[i - 1], p[i]] + (if (hasNext) d[p[k], p[k + 1]] else 0L)
    return added - removed
}

/**
 * Ordre précédent restreint aux articles présents (premières occurrences seulement) ; les
 * nouveaux articles, par identifiant croissant, sont insérés un à un à la position qui
 * augmente le moins le coût (à égalité, la plus en tête ; la fin compte comme position).
 */
internal fun previousPath(
    d: DistanceMatrix,
    ids: List<String>,
    previous: List<String>,
): IntArray {
    val index = HashMap<String, Int>()
    for (j in 1 until ids.size) index[ids[j]] = j
    val path = ArrayList<Int>(ids.size)
    path.add(0)
    val seen = BooleanArray(ids.size)
    for (id in previous) {
        val j = index[id]
        if (j != null && !seen[j]) {
            seen[j] = true
            path.add(j)
        }
    }
    // Les indices suivent déjà l'ordre canonique des identifiants.
    for (j in 1 until ids.size) {
        if (seen[j]) continue
        var bestPos = -1
        var bestInc = 0L
        for (pos in 1..path.size) {
            val prev = path[pos - 1]
            val inc =
                if (pos < path.size) {
                    d[prev, j] + d[j, path[pos]] - d[prev, path[pos]]
                } else {
                    d[prev, j]
                }
            if (bestPos == -1 || inc < bestInc) {
                bestPos = pos
                bestInc = inc
            }
        }
        path.add(bestPos, j)
    }
    return path.toIntArray()
}
