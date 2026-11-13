package fr.parcourses.core.sorting

import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SnapshotEntry
import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.model.SortStart

/**
 * Magasin synthétique des mesures de performance (#30), identique à celui d'iOS
 * (`SyntheticStore.swift`) : même générateur, même graphe, donc même ordre attendu.
 */
internal object SyntheticStore {
    const val ITEMS = 80
    const val STORE_PRODUCTS = 400
    const val EDGES = 3000
    const val CATEGORIES = 20
    private const val MAX_WEIGHT = 5000L
    private const val SEED = 42L
    private const val CONFIDENCE_Q = 900L

    /** Générateur congruentiel 64 bits (constantes de Knuth), reproduit tel quel en Swift. */
    private class Lcg(
        private var state: Long,
    ) {
        fun next(bound: Long): Long {
            state = state * MULTIPLIER + INCREMENT
            return (state ushr SHIFT) % bound
        }

        private companion object {
            const val MULTIPLIER = 6_364_136_223_846_793_005L
            const val INCREMENT = 1_442_695_040_888_963_407L
            const val SHIFT = 33
        }
    }

    fun productId(k: Int): String = "p-${k.toString().padStart(3, '0')}"

    /** [products] produits, [EDGES] arêtes distinctes, 80 articles sur les produits 0 à 79. */
    fun input(products: Int): SortInput {
        val random = Lcg(SEED)
        val seen = HashSet<Int>()
        val pairs = ArrayList<Pair<Int, Int>>()
        while (pairs.size < EDGES) {
            val a = random.next(products.toLong()).toInt()
            val b = random.next(products.toLong()).toInt()
            if (a == b) continue
            val pair = minOf(a, b) to maxOf(a, b)
            if (seen.add(pair.first * products + pair.second)) pairs.add(pair)
        }
        val entries = List(CATEGORIES) { SnapshotEntry(productId(it), random.next(MAX_WEIGHT)) }
        val edges = pairs.map { (a, b) -> SnapshotEdge(productId(a), productId(b), random.next(MAX_WEIGHT)) }
        return SortInput(
            categories = List(CATEGORIES) { SortCategory("c-$it", it.toLong()) },
            snapshot = SortSnapshot(CONFIDENCE_Q, entries, edges),
            items = List(ITEMS) { SortItem("i-$it", productId(it), "c-${it % CATEGORIES}", "n$it") },
            start = SortStart.Entry,
            previousOrder = null,
        )
    }
}
