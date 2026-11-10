package fr.parcourses.core.sorting

import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SnapshotEntry
import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortOutput
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.model.SortStart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class SortPerformanceTest {
    // Budget #10 §5 : 80 articles et 3 000 arêtes sous 20 ms sur la JVM. Le seuil n'est pas relevé pour absorber un
    // dépassement. On compare le meilleur des 21 passages : la charge de la machine (CI, autre build) ne fait
    // qu'allonger un passage, jamais l'écourter, alors que la médiane la suit (#54, échec en local sous charge).
    // La médiane reste affichée pour suivre l'objectif de 5 ms. La mesure sur appareil est celle de
    // :baselineprofile (ShoppingBenchmark, A12).
    @Test
    fun sharedVectorsWithinBudget() {
        for (id in listOf("031-large-80-items-partial-graph", "032-large-80-items-recompute-with-previous")) {
            val vector = SortVectors.byId(id)
            assertEquals(ITEMS, vector.input.items.size)
            assertEquals(vector.expected, sortItems(vector.input))
            assertMinWithinBudget(id, vector.input)
        }
    }

    // Budget #10 : presque toutes les paires des 80 produits de la liste sont reliées.
    @Test
    fun denseGraphWithinBudget() {
        val input = syntheticInput(products = ITEMS)
        assertSyntheticOutput(input)
        assertMinWithinBudget("dense-80-produits", input)
    }

    // Mesure seule, hors budget : les Dijkstra parcourent aussi des produits absents de la liste.
    @Test
    fun largeStoreGraphIsMeasured() {
        val input = syntheticInput(products = STORE_PRODUCTS)
        assertSyntheticOutput(input)
        measure("magasin-400-produits", input)
    }

    private fun assertSyntheticOutput(input: SortInput) {
        assertEquals(EDGES, input.snapshot?.edges?.size)
        val output = sortItems(input)
        assertEquals(SortOutput.Mode.Learned, output.mode)
        assertEquals(input.items.map { it.id }.sorted(), output.order.sorted())
    }

    private fun assertMinWithinBudget(
        name: String,
        input: SortInput,
    ) {
        val (minMs, medianMs) = measure(name, input)
        assertTrue("$name : min $minMs ms >= $THRESHOLD_MS ms (médiane $medianMs ms)", minMs < THRESHOLD_MS)
    }

    private fun measure(
        name: String,
        input: SortInput,
    ): Pair<Double, Double> {
        repeat(WARMUP) { sortItems(input) }
        val timings =
            List(RUNS) {
                val t0 = System.nanoTime()
                sortItems(input)
                System.nanoTime() - t0
            }.sorted()
        val minMs = timings.first() / NANOS_PER_MS
        val medianMs = timings[RUNS / 2] / NANOS_PER_MS
        println("sortItems $name : min $minMs ms, médiane $medianMs ms")
        return minMs to medianMs
    }

    // Graphe tiré avec une graine fixe : 3 000 arêtes distinctes.
    private fun syntheticInput(products: Int): SortInput {
        val random = Random(SEED)
        val id = { k: Int -> "p-${k.toString().padStart(3, '0')}" }
        val pairs = LinkedHashSet<Pair<Int, Int>>()
        while (pairs.size < EDGES) {
            val a = random.nextInt(products)
            val b = random.nextInt(products)
            if (a != b) pairs.add(minOf(a, b) to maxOf(a, b))
        }
        return SortInput(
            categories = List(CATEGORIES) { SortCategory("c-$it", it.toLong()) },
            snapshot =
                SortSnapshot(
                    confidenceQ = 900,
                    entries = List(CATEGORIES) { SnapshotEntry(id(it), random.nextLong(MAX_WEIGHT)) },
                    edges = pairs.map { (a, b) -> SnapshotEdge(id(a), id(b), random.nextLong(MAX_WEIGHT)) },
                ),
            items = List(ITEMS) { SortItem("i-$it", id(it), "c-${it % CATEGORIES}", "n$it") },
            start = SortStart.Entry,
            previousOrder = null,
        )
    }

    private companion object {
        const val ITEMS = 80
        const val EDGES = 3000
        const val STORE_PRODUCTS = 400
        const val CATEGORIES = 20
        const val MAX_WEIGHT = 5000L
        const val SEED = 42
        const val WARMUP = 50
        const val RUNS = 21
        const val NANOS_PER_MS = 1_000_000.0
        const val THRESHOLD_MS = 20.0
    }
}
