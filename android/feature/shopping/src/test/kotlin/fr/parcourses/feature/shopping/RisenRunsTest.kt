package fr.parcourses.feature.shopping

import org.junit.Assert.assertEquals
import org.junit.Test

class RisenRunsTest {
    private fun run(
        aisle: String,
        vararg ids: String,
        occurrence: Int = 0,
    ) = ShoppingSection(aisle, aisle, ids.map { ShoppingRow(it, it, null, false, aisle) }, occurrence)

    @Test
    fun aRunThatOvertakesAnotherIsTaggedAsLearned() {
        val after = listOf(run("produce", "a"), run("savory-grocery", "c"), run("dairy", "b"))
        assertEquals(setOf("savory-grocery"), risenRuns(listOf("a", "b", "c"), after))
    }

    @Test
    fun aRunMovingUpBecauseAnotherIsDoneIsNotTagged() {
        // Tout le rayon frais est pris : les suivants remontent d'une place sans rien avoir appris.
        assertEquals(emptySet<String>(), risenRuns(listOf("a", "b", "c"), listOf(run("dairy", "b"), run("x", "c"))))
    }

    @Test
    fun anAisleCrossedTwiceDoesNotTagItsNeighbour() {
        // [produce (a), dairy (b), produce#1 (c)] ; a est pris : c devient la première suite de produce.
        val after = listOf(run("dairy", "b"), run("produce", "c"))
        assertEquals(emptySet<String>(), risenRuns(listOf("a", "b", "c"), after))
    }

    @Test
    fun anItemAddedOnTheWayDoesNotTagAnything() {
        val after = listOf(run("produce", "new"), run("dairy", "b"), run("produce", "c", occurrence = 1))
        assertEquals(emptySet<String>(), risenRuns(listOf("b", "c"), after))
    }
}
