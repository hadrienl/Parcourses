package fr.parcourses.feature.shopping

import org.junit.Assert.assertEquals
import org.junit.Test

class RisenRunsTest {
    @Test
    fun aRunThatOvertakesAnotherIsTaggedAsLearned() {
        val before = listOf("produce#0", "dairy#0", "savory-grocery#0")
        val after = listOf("produce#0", "savory-grocery#0", "dairy#0")
        assertEquals(setOf("savory-grocery#0"), risenRuns(before, after))
    }

    @Test
    fun aRunMovingUpBecauseAnotherIsDoneIsNotTagged() {
        // Tout le rayon frais est pris : les suivants remontent d'une place sans rien avoir appris.
        val before = listOf("produce#0", "dairy#0", "savory-grocery#0")
        assertEquals(emptySet<String>(), risenRuns(before, listOf("dairy#0", "savory-grocery#0")))
        assertEquals(emptySet<String>(), risenRuns(before, before))
    }
}
