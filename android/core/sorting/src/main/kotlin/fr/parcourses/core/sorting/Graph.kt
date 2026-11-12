package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortSnapshot
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

    /** Indice d'un produit dans les distances ; -1 s'il est absent du graphe ou `null`. */
    fun indexOf(productId: String?): Int = productId?.let { index[it] } ?: -1

    /** Distances depuis l'entrée, par indice de produit ([SORT_INFINITY] si inaccessible). */
    fun distancesFromEntry(): LongArray = dijkstra(entryTargets, entryCosts, source = -1)

    /** Distances depuis un produit du graphe, désigné par son indice. */
    fun distancesFrom(source: Int): LongArray = dijkstra(neighbours[source], adjacency[source], source)

    /**
     * Dijkstra entier, file ordonnée par (distance, indice = ordre des identifiants).
     * [firstTargets]/[firstCosts] sont les arcs sortants de la source. La file est un tas de
     * primitives : ni allocation par relaxation, ni `Long` emballé à chaque comparaison (#30).
     */
    private fun dijkstra(
        firstTargets: IntArray,
        firstCosts: LongArray,
        source: Int,
    ): LongArray {
        val dist = LongArray(index.size) { SORT_INFINITY }
        val done = BooleanArray(index.size)
        val queue = NodeHeap(index.size)
        if (source >= 0) {
            dist[source] = 0
            done[source] = true
        }
        for (k in firstTargets.indices) relax(dist, queue, firstTargets[k], firstCosts[k])
        while (queue.isNotEmpty()) {
            val d = queue.topDistance()
            val u = queue.topNode()
            queue.pop()
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
        queue: NodeHeap,
        v: Int,
        nd: Long,
    ) {
        if (nd < dist[v]) {
            dist[v] = nd
            queue.push(nd, v)
        }
    }
}

/**
 * Tas binaire minimal de clés (distance, indice), rangées dans deux tableaux parallèles.
 * L'ordre est celui de l'ancienne `PriorityQueue<LongArray>` : distance, puis indice.
 */
internal class NodeHeap(
    capacity: Int,
) {
    private var distances = LongArray(maxOf(capacity, 1))
    private var nodes = IntArray(maxOf(capacity, 1))
    private var size = 0

    fun isNotEmpty(): Boolean = size > 0

    fun topDistance(): Long = distances[0]

    fun topNode(): Int = nodes[0]

    fun push(
        distance: Long,
        node: Int,
    ) {
        if (size == distances.size) {
            distances = distances.copyOf(size * 2)
            nodes = nodes.copyOf(size * 2)
        }
        var child = size++
        while (child > 0) {
            val parent = (child - 1) / 2
            if (!precedes(distance, node, parent)) break
            move(parent, child)
            child = parent
        }
        distances[child] = distance
        nodes[child] = node
    }

    /** Retire la clé du sommet. */
    fun pop() {
        size--
        if (size == 0) return
        val distance = distances[size]
        val node = nodes[size]
        var parent = 0
        var child = 1
        while (child < size) {
            if (child + 1 < size && precedes(distances[child + 1], nodes[child + 1], child)) child++
            if (!keyPrecedes(distances[child], nodes[child], distance, node)) break
            move(child, parent)
            parent = child
            child = 2 * parent + 1
        }
        distances[parent] = distance
        nodes[parent] = node
    }

    /** Vrai si (distance, node) précède strictement la clé rangée en [slot]. */
    private fun precedes(
        distance: Long,
        node: Int,
        slot: Int,
    ): Boolean = keyPrecedes(distance, node, distances[slot], nodes[slot])

    private fun move(
        from: Int,
        to: Int,
    ) {
        distances[to] = distances[from]
        nodes[to] = nodes[from]
    }
}

/** Ordre des clés de la file : distance, puis indice. */
private fun keyPrecedes(
    distance: Long,
    node: Int,
    otherDistance: Long,
    otherNode: Int,
): Boolean = distance < otherDistance || (distance == otherDistance && node < otherNode)
