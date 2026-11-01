package fr.parcourses.core.sorting

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SortPerformanceTest {
    // Objectif : 5 ms pour 80 articles. Le seuil de 20 ms, comme sur iOS, laisse de la marge
    // à la CI partagée ; la médiane mesurée est affichée pour suivre l'objectif.
    @Test
    fun sorts80ItemsWithinBudget() {
        for (id in listOf("031-large-80-items-partial-graph", "032-large-80-items-recompute-with-previous")) {
            val vector = SortVectors.byId(id)
            assertEquals(80, vector.input.items.size)
            repeat(WARMUP) { sortItems(vector.input) }
            val timings =
                List(RUNS) {
                    val t0 = System.nanoTime()
                    assertEquals(vector.expected, sortItems(vector.input))
                    System.nanoTime() - t0
                }.sorted()
            val medianMs = timings[RUNS / 2] / 1_000_000.0
            println("sortItems $id : médiane $medianMs ms")
            assertTrue("$id : médiane $medianMs ms >= $THRESHOLD_MS ms", medianMs < THRESHOLD_MS)
        }
    }

    private companion object {
        const val WARMUP = 50
        const val RUNS = 21
        const val THRESHOLD_MS = 20.0
    }
}
