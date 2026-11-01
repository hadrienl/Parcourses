package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortOutput
import fr.parcourses.core.model.SortStart
import kotlin.math.abs

/** Distance « infinie » : 2^40, avec addition saturée (#5 §2.6). */
const val SORT_INFINITY: Long = 1L shl 40

private const val PERCENT = 100L

/**
 * Trie les articles restants selon le trajet appris du magasin (#5), ou par catégorie si
 * le graphe est absent ou trop peu fiable.
 *
 * Fonction pure et déterministe, en entiers `Long` uniquement : même entrée, même ordre
 * qu'iOS et que la référence `shared/reference/sort.ts`, quel que soit l'ordre des listes
 * fournies. Appelée hors du thread principal (`Dispatchers.Default`) par l'app.
 *
 * @throws fr.parcourses.core.model.SortError si un identifiant n'est pas en `[0-9a-z-]+`,
 * si un article ou une catégorie est en double, ou si un poids est négatif.
 */
fun sortItems(input: SortInput): SortOutput {
    validate(input)
    val snapshot = input.snapshot
    if (snapshot == null || snapshot.confidenceQ < input.params.confThresholdQ) {
        return SortOutput(SortOutput.Mode.Fallback, fallbackOrder(input.items, input.categories), null)
    }
    // Ordre canonique : le résultat ne dépend pas de l'ordre fourni.
    val items = input.items.sortedWith { x, y -> compareIds(x.id, y.id) }
    val ids = listOf("") + items.map { it.id }
    val d = buildMatrix(input, items, StoreGraph(snapshot, input.params))

    var path = twoOpt(d, nearestNeighbour(d, ids), input.params.twoOptMaxPasses)
    val previousOrder = input.previousOrder
    if (!previousOrder.isNullOrEmpty()) {
        // Hystérésis : on garde l'ordre précédent tant que le gain reste sous le seuil.
        val previous = previousPath(d, ids, previousOrder)
        if (pathCost(d, path) * PERCENT > pathCost(d, previous) * (PERCENT - input.params.reorderMinGainPct)) {
            path = previous
        }
    }
    return SortOutput(SortOutput.Mode.Learned, path.drop(1).map { ids[it] }, pathCost(d, path))
}

/**
 * Indice ordinal d'une catégorie : liste triée par `(rank, id)`, numérotée `0..m-1`. Une
 * catégorie absente ou inconnue prend l'indice de `other`, sinon `m-1` (0 si liste vide).
 */
private fun rankResolver(categories: List<SortCategory>): (String?) -> Long {
    val sorted =
        categories.sortedWith(
            compareBy<SortCategory> { it.rank }.thenComparator {
                x,
                y,
                ->
                compareIds(x.id, y.id)
            },
        )
    val index = sorted.withIndex().associate { (i, c) -> c.id to i.toLong() }
    val unknown = index["other"] ?: maxOf(0, sorted.size - 1).toLong()
    return { id -> id?.let { index[it] } ?: unknown }
}

/** Repli : tri par (indice de catégorie, nom normalisé en octets UTF-8, identifiant). */
private fun fallbackOrder(
    items: List<SortItem>,
    categories: List<SortCategory>,
): List<String> {
    val rank = rankResolver(categories)
    return items
        .sortedWith { x, y ->
            rank(x.categoryId).compareTo(rank(y.categoryId)).takeIf { it != 0 }
                ?: compareBytes(x.normalizedName, y.normalizedName).takeIf { it != 0 }
                ?: compareIds(x.id, y.id)
        }.map { it.id }
}

/**
 * Matrice `d(x, y) = min(graph_dist, cat_cost)`. Le nœud 0 est le départ, sans catégorie :
 * `cat_cost(départ, y) = UNKNOWN_BASE + CAT_STEP × idx(y)`. La colonne 0 reste à 0.
 * `graph_dist` vaut 0 entre deux nœuds du même produit, même absent du graphe.
 */
private fun buildMatrix(
    input: SortInput,
    items: List<SortItem>,
    graph: StoreGraph,
): DistanceMatrix {
    val rank = rankResolver(input.categories)
    val ranks = LongArray(items.size + 1)
    val products = arrayOfNulls<String>(items.size + 1)
    val graphIndex = IntArray(items.size + 1) { -1 }
    items.forEachIndexed { k, item ->
        ranks[k + 1] = rank(item.categoryId)
        products[k + 1] = item.productId
        graphIndex[k + 1] = graph.indexOf(item.productId)
    }
    val start = input.start
    if (start is SortStart.Product) {
        products[0] = start.productId
        graphIndex[0] = graph.indexOf(start.productId)
    }
    val entryDistances = if (start is SortStart.Entry) graph.distancesFromEntry() else null
    // Un Dijkstra par produit distinct, mis en cache.
    val cache = HashMap<Int, LongArray>()
    val matrix = DistanceMatrix(items.size + 1)
    val params = input.params
    for (i in 0 until matrix.size) {
        val source = graphIndex[i]
        val distances =
            when {
                i == 0 && entryDistances != null -> entryDistances
                source >= 0 -> cache.getOrPut(source) { graph.distancesFrom(source) }
                else -> null
            }
        for (j in 1 until matrix.size) {
            if (i != j) {
                val gap = if (i == 0) ranks[j] else abs(ranks[i] - ranks[j])
                val cat = params.unknownBase + params.catStep * gap
                val graphDist =
                    if (products[i] != null && products[i] == products[j]) {
                        0L
                    } else {
                        graphDistance(distances, graphIndex[j])
                    }
                matrix.cells[i * matrix.size + j] = minOf(graphDist, cat)
            }
        }
    }
    return matrix
}

/** Distance vers un produit du graphe ; infinie si la source ou la cible en sont absentes. */
private fun graphDistance(
    distances: LongArray?,
    target: Int,
): Long = if (distances != null && target >= 0) distances[target] else SORT_INFINITY
