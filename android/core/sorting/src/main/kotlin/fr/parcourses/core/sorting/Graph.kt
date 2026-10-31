package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortSnapshot
import java.util.PriorityQueue
import java.util.TreeMap

/** Addition saturée à [SORT_INFINITY] (toutes les valeurs sont positives). */
internal fun satAdd(
    a: Long,
    b: Long,
): Long {
    val s = a + b
    return if (s >= SORT_INFINITY) SORT_INFINITY else s
}

/** Coût d'une arête : plus le voisinage est observé, plus il est court. Division tronquée. */
internal fun edgeCost(
    weightQ: Long,
    params: SortParams,
): Long = params.costScale * PER_MILLE / (PER_MILLE + weightQ)

internal const val PER_MILLE = 1000L

/**
 * Graphe du magasin. Les produits sont numérotés par identifiant croissant ; le nœud
 * virtuel de l'entrée n'a que des arcs sortants : un chemin ne le traverse jamais.
 */
internal class StoreGraph(
    snapshot: SortSnapshot,
    params: SortParams,
) {
    private val index: Map<String, Int>
    private val adjacency: Array<LongArray>
    private val neighbours: Array<IntArray>
    private val entryTargets: IntArray
    private val entryCosts: LongArray

    init {
        // Arêtes non orientées ; boucles ignorées ; en cas de doublon, coût minimal.
        // TreeMap : itération toujours dans l'ordre des identifiants.
        val best = TreeMap<String, TreeMap<String, Long>>(::compareIds)

        fun put(
            a: String,
            b: String,
            c: Long,
        ) {
            val m = best.getOrPut(a) { TreeMap(::compareIds) }
            val old = m[b]
            if (old == null || c < old) m[b] = c
        }
        for (e in snapshot.edges) {
            if (e.a == e.b) continue
            val c = edgeCost(e.weightQ, params)
            put(e.a, e.b, c)
            put(e.b, e.a, c)
        }
        val entryBest = TreeMap<String, Long>(::compareIds)
        for (e in snapshot.entries) {
            val c = edgeCost(e.weightQ, params)
            val old = entryBest[e.productId]
            if (old == null || c < old) entryBest[e.productId] = c
        }
        val ids = sortedSetOf(Comparator(::compareIds))
        ids.addAll(best.keys)
        ids.addAll(entryBest.keys)
        index = ids.withIndex().associate { (i, id) -> id to i }
        neighbours = Array(ids.size) { IntArray(0) }
        adjacency = Array(ids.size) { LongArray(0) }
        for ((a, m) in best) {
            val i = index.getValue(a)
            neighbours[i] = m.keys.map { index.getValue(it) }.toIntArray()
            adjacency[i] = m.values.toLongArray()
        }
        entryTargets = entryBest.keys.map { index.getValue(it) }.toIntArray()
        entryCosts = entryBest.values.toLongArray()
    }

    /** Distances depuis l'entrée vers chaque produit ([SORT_INFINITY] si inaccessible). */
    fun fromEntry(): (String?) -> Long = lookup(dijkstra(entryTargets, entryCosts, source = -1))

    /** Distances depuis un produit ; un produit absent du graphe n'atteint que lui-même. */
    fun fromProduct(productId: String): (String?) -> Long {
        val s = index[productId] ?: return { if (it == productId) 0L else SORT_INFINITY }
        return lookup(dijkstra(neighbours[s], adjacency[s], source = s))
    }

    private fun lookup(dist: LongArray): (String?) -> Long =
        { id -> id?.let { index[it] }?.let { dist[it] } ?: SORT_INFINITY }

    /**
     * Dijkstra entier, file ordonnée par (distance, indice = ordre des identifiants).
     * [firstTargets]/[firstCosts] sont les arcs sortants de la source.
     */
    private fun dijkstra(
        firstTargets: IntArray,
        firstCosts: LongArray,
        source: Int,
    ): LongArray {
        val dist = LongArray(index.size) { SORT_INFINITY }
        val done = BooleanArray(index.size)
        val queue = PriorityQueue<LongArray>(compareBy<LongArray>({ it[0] }, { it[1] }))
        if (source >= 0) {
            dist[source] = 0
            done[source] = true
        }
        for (k in firstTargets.indices) relax(dist, queue, firstTargets[k], firstCosts[k])
        while (queue.isNotEmpty()) {
            val (d, uLong) = queue.poll()
            val u = uLong.toInt()
            if (done[u] || d > dist[u]) continue
            done[u] = true
            val targets = neighbours[u]
            val costs = adjacency[u]
            for (k in targets.indices) {
                if (!done[targets[k]]) relax(dist, queue, targets[k], satAdd(d, costs[k]))
            }
        }
        return dist
    }

    private fun relax(
        dist: LongArray,
        queue: PriorityQueue<LongArray>,
        v: Int,
        nd: Long,
    ) {
        if (nd < dist[v]) {
            dist[v] = nd
            queue.add(longArrayOf(nd, v.toLong()))
        }
    }
}
