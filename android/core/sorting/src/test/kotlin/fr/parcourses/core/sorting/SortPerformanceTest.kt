package fr.parcourses.core.sorting

import org.junit.Assert.assertTrue
import org.junit.Test

class SortPerformanceTest {
    // Budget #10 §5 : moins de 20 ms pour 80 articles sur la JVM, après préchauffage.
    @Test
    fun sorts80ItemsWithinBudget() {
        val vector = SortVectors.byId("031-large-80-items-partial-graph")
        assertTrue(vector.input.items.size >= 80)
        repeat(WARMUP) { sortItems(vector.input) }
        val timings =
            List(RUNS) {
                val t0 = System.nanoTime()
                sortItems(vector.input)
                System.nanoTime() - t0
            }.sorted()
        val medianMs = timings[RUNS / 2] / 1_000_000.0
        assertTrue("médiane $medianMs ms > $BUDGET_MS ms", medianMs < BUDGET_MS)
    }

    private companion object {
        const val WARMUP = 50
        const val RUNS = 21
        const val BUDGET_MS = 20.0
    }
}
