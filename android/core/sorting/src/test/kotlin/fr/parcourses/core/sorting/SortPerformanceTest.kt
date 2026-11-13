package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortOutput
import fr.parcourses.core.model.SortStart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

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
            assertEquals(SyntheticStore.ITEMS, vector.input.items.size)
            assertEquals(vector.expected, sortItems(vector.input))
            assertMinWithinBudget(id) { sortItems(vector.input) }
        }
    }

    // Budget #10 : presque toutes les paires des 80 produits de la liste sont reliées.
    @Test
    fun denseGraphWithinBudget() {
        val input = SyntheticStore.input(products = SyntheticStore.ITEMS)
        assertSyntheticOutput(input, DENSE_COST, DENSE_HEAD)
        assertMinWithinBudget("dense-80-produits") { sortItems(input) }
    }

    // #30 : magasin de 400 produits, 3 000 arêtes, 80 articles. Premier tri d'une visite, sans précalcul : les
    // Dijkstra parcourent aussi les produits absents de la liste.
    @Test
    fun largeStoreFirstSortWithinBudget() {
        val input = SyntheticStore.input(products = SyntheticStore.STORE_PRODUCTS)
        assertSyntheticOutput(input, STORE_COST, STORE_HEAD)
        assertMinWithinBudget("magasin-400-produits, premier tri") { sortItems(input) }
    }

    // #30 : recalcul après une coche avec le magasin préparé ; les distances viennent du cache.
    @Test
    fun largeStoreRecomputeWithinBudget() {
        val input = SyntheticStore.input(products = SyntheticStore.STORE_PRODUCTS)
        val prepared = PreparedStore(requireNotNull(input.snapshot), input.params)
        val first = sortItems(input, prepared)
        val checked = input.items.first { it.id == first.order.first() }
        val recompute =
            input.copy(
                items = input.items - checked,
                start = SortStart.Product(requireNotNull(checked.productId)),
                previousOrder = first.order.drop(1),
            )
        assertEquals(sortItems(recompute), sortItems(recompute, prepared))
        assertMinWithinBudget("magasin-400-produits, recalcul préparé") { sortItems(recompute, prepared) }
    }

    // Même coût et même début d'ordre qu'iOS (PerformanceTests.swift) sur le même graphe.
    private fun assertSyntheticOutput(
        input: SortInput,
        cost: Long,
        head: List<String>,
    ) {
        assertEquals(SyntheticStore.EDGES, input.snapshot?.edges?.size)
        val output = sortItems(input)
        assertEquals(SortOutput.Mode.Learned, output.mode)
        assertEquals(input.items.map { it.id }.sorted(), output.order.sorted())
        assertEquals(cost, output.cost)
        assertEquals(head, output.order.take(head.size))
    }

    private fun assertMinWithinBudget(
        name: String,
        sort: () -> SortOutput,
    ) {
        repeat(WARMUP) { sort() }
        val timings =
            List(RUNS) {
                val t0 = System.nanoTime()
                sort()
                System.nanoTime() - t0
            }.sorted()
        val minMs = timings.first() / NANOS_PER_MS
        val medianMs = timings[RUNS / 2] / NANOS_PER_MS
        println("sortItems $name : min $minMs ms, médiane $medianMs ms")
        assertTrue("$name : min $minMs ms >= $THRESHOLD_MS ms (médiane $medianMs ms)", minMs < THRESHOLD_MS)
    }

    private companion object {
        const val WARMUP = 50
        const val RUNS = 21
        const val NANOS_PER_MS = 1_000_000.0
        const val THRESHOLD_MS = 20.0
        const val DENSE_COST = 13_683L
        val DENSE_HEAD = listOf("i-7", "i-78", "i-13", "i-76", "i-58")
        const val STORE_COST = 22_848L
        val STORE_HEAD = listOf("i-13", "i-57", "i-70", "i-49", "i-17")
    }
}
