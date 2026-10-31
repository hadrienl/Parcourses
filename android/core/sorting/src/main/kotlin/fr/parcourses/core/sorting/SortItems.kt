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
 */
private fun buildMatrix(
    input: SortInput,
    items: List<SortItem>,
    graph: StoreGraph,
): Array<LongArray> {
    val params = input.params
    val rank = rankResolver(input.categories)
    val ranks = LongArray(items.size + 1)
    val products = arrayOfNulls<String>(items.size + 1)
    items.forEachIndexed { k, item ->
        ranks[k + 1] = rank(item.categoryId)
        products[k + 1] = item.productId
    }
    // Un Dijkstra par produit distinct, mis en cache.
    val cache = HashMap<String, (String?) -> Long>()
    val fromStart =
        when (val start = input.start) {
            SortStart.Entry -> graph.fromEntry()
            is SortStart.Product -> graph.fromProduct(start.productId)
        }
    val n = items.size + 1
    return Array(n) { i ->
        val a = products[i]
        val dist: (String?) -> Long =
            when {
                i == 0 -> fromStart
                a == null -> { _ -> SORT_INFINITY }
                else -> cache.getOrPut(a) { graph.fromProduct(a) }
            }
        LongArray(n) { j ->
            if (j == 0 || i == j) {
                0L
            } else {
                val cat =
                    if (i == 0) {
                        params.unknownBase + params.catStep * ranks[j]
                    } else {
                        params.unknownBase + params.catStep * abs(ranks[i] - ranks[j])
                    }
                minOf(dist(products[j]), cat)
            }
        }
    }
}
