package fr.parcourses.core.sorting

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.Parameterized
import kotlin.random.Random

// Chaque vecteur partagé doit donner exactement le mode, l'ordre et le coût attendus.
@RunWith(Parameterized::class)
class SortVectorTest(
    private val vector: SortVector,
) {
    companion object {
        @JvmStatic
        @Parameterized.Parameters(name = "{0}")
        fun vectors(): List<SortVector> = SortVectors.all()
    }

    @Test
    fun matchesExpectedOutput() {
        assertEquals(vector.expected, sortItems(vector.input))
    }

    @Test
    fun doesNotDependOnInputOrder() {
        val random = Random(vector.id.hashCode())
        val input = vector.input
        val shuffled =
            input.copy(
                categories = input.categories.shuffled(random),
                items = input.items.shuffled(random),
                snapshot =
                    input.snapshot?.let {
                        it.copy(entries = it.entries.shuffled(random), edges = it.edges.shuffled(random))
                    },
            )
        assertEquals(vector.expected, sortItems(shuffled))
    }
}
