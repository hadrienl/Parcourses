package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.shopping.RouteKnowledge
import fr.parcourses.feature.shopping.ShoppingSummary
import fr.parcourses.feature.storepicker.StorePickerOutcome
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BackStackOperationsTest {
    private val store = StorePickerOutcome.Store("s1")

    private fun stack(vararg keys: NavKey) = mutableListOf(*keys)

    @Test
    fun theStorePickerOpensOnlyOnce() {
        val stack = stack(Route.Lists, Route.ListDetail("a"))
        stack.openStorePicker("a")
        stack.openStorePicker("a")
        assertEquals(3, stack.size)
    }

    @Test
    fun finishingPopsTheScreenAndReturnsTheChoiceForItsList() {
        val picker = Route.StorePicker("a")
        val stack = stack(Route.Lists, Route.ListDetail("a"), picker)
        assertEquals(StoreChoice("a", store), stack.finishStorePicker(picker.slot, store))
        assertEquals(2, stack.size)
    }

    @Test
    fun aSecondEventDoesNotPopAnotherScreen() {
        val picker = Route.StorePicker("a")
        val stack = stack(Route.Lists, Route.ListDetail("a"), picker)
        stack.finishStorePicker(picker.slot, store)
        assertNull(stack.finishStorePicker(picker.slot, StorePickerOutcome.WithoutStore))
        assertEquals(listOf(Route.Lists, Route.ListDetail("a", (stack[1] as Route.ListDetail).slot)), stack)
    }

    @Test
    fun aChoiceAfterTheUserWentBackIsIgnored() {
        val picker = Route.StorePicker("a")
        val stack = stack(Route.Lists, Route.ListDetail("a"), picker)
        stack.removeAt(stack.lastIndex)
        assertNull(stack.finishStorePicker(picker.slot, store))
        assertEquals(2, stack.size)
    }

    @Test
    fun aChoiceFromAnotherPickerIsIgnored() {
        val stack = stack(Route.Lists, Route.StorePicker("a"))
        assertNull(stack.finishStorePicker("autre", store))
        assertEquals(2, stack.size)
    }

    @Test
    fun aRemapBeforeTheChoiceGivesTheNewListId() {
        val picker = Route.StorePicker("old")
        val stack = stack(Route.Lists, Route.ListDetail("old"), picker)
        stack.applyRemap(IdentifierRemap(mapOf("old" to "new")))
        assertEquals("new", (stack[2] as Route.StorePicker).listId)
        assertEquals("new", (stack[1] as Route.ListDetail).listId)
        // Même écran après la reprise de compte.
        assertEquals(picker.slot, (stack[2] as Route.StorePicker).slot)
        assertEquals(StoreChoice("new", store), stack.finishStorePicker(picker.slot, store))
    }
}

class ShoppingNavigationTest {
    private fun stack(vararg keys: NavKey) = mutableListOf(*keys)

    @Test
    fun aStoreChoiceOpensShoppingOnTopOfItsList() {
        val stack = stack(Route.Lists, Route.ListDetail("a"))
        assertTrue(stack.openShopping(StoreChoice("a", StorePickerOutcome.Store("s1"))))
        val shopping = stack.last() as Route.Shopping
        assertEquals("a", shopping.listId)
        assertEquals("s1", shopping.storeId)
    }

    @Test
    fun withoutAStoreShoppingHasNoStoreId() {
        val stack = stack(Route.Lists, Route.ListDetail("a"))
        assertTrue(stack.openShopping(StoreChoice("a", StorePickerOutcome.WithoutStore)))
        assertNull((stack.last() as Route.Shopping).storeId)
    }

    @Test
    fun aChoiceForAnotherListIsIgnored() {
        val stack = stack(Route.Lists, Route.ListDetail("b"))
        assertFalse(stack.openShopping(StoreChoice("a", StorePickerOutcome.Store("s1"))))
        assertEquals(2, stack.size)
    }

    @Test
    fun aChoiceWhoseListIsNoLongerOnTopIsIgnored() {
        val stack = stack(Route.Lists)
        assertFalse(stack.openShopping(StoreChoice("a", StorePickerOutcome.Store("s1"))))
        assertEquals(1, stack.size)
    }

    @Test
    fun aChoiceIsNotAppliedTwice() {
        val stack = stack(Route.Lists, Route.ListDetail("a"))
        val choice = StoreChoice("a", StorePickerOutcome.Store("s1"))
        assertTrue(stack.openShopping(choice))
        assertFalse(stack.openShopping(choice))
        assertEquals(3, stack.size)
    }

    @Test
    fun backOnlyPopsTheScreenItBelongsTo() {
        val shopping = Route.Shopping("a", "s1")
        val stack = stack(Route.Lists, Route.ListDetail("a"), shopping)
        assertTrue(stack.popIfTop(shopping.slot))
        // Double appui : le sommet est maintenant la liste, elle ne saute pas.
        assertFalse(stack.popIfTop(shopping.slot))
        assertEquals(2, stack.size)
    }

    @Test
    fun backOnTheStorePickerIsGuardedToo() {
        val picker = Route.StorePicker("a")
        val stack = stack(Route.Lists, Route.ListDetail("a"), picker)
        assertTrue(stack.popIfTop(picker.slot))
        assertFalse(stack.popIfTop(picker.slot))
        assertEquals(2, stack.size)
    }

    @Test
    fun aRemapFollowsTheShoppingList() {
        val shopping = Route.Shopping("old", "s1")
        val stack = stack(Route.Lists, Route.ListDetail("old"), shopping)
        stack.applyRemap(IdentifierRemap(mapOf("old" to "new")))
        val moved = stack.last() as Route.Shopping
        assertEquals("new", moved.listId)
        assertEquals(shopping.slot, moved.slot)
    }

    private val visit = ResumableVisit("a", "s1")

    @Test
    fun aColdStartResumesTheOpenVisitOnce() =
        runTest {
            val gate = LaunchResume()
            val stack = stack(Route.Lists)
            assertTrue(stack.resumeOnLaunch(gate, coldStart = true) { visit })
            assertEquals(listOf("Lists", "ListDetail", "Shopping"), stack.map { it::class.simpleName })
        }

    @Test
    fun aRecreationNeverResumesAgain() =
        runTest {
            val gate = LaunchResume()
            val stack = stack(Route.Lists)
            stack.resumeOnLaunch(gate, coldStart = true) { visit }
            // La personne revient à l'écran Listes, puis tourne le téléphone : l'effet de lancement est rejoué.
            stack.removeAt(stack.lastIndex)
            stack.removeAt(stack.lastIndex)
            var looked = false
            assertFalse(stack.resumeOnLaunch(gate, coldStart = false) { visit.also { looked = true } })
            // Même un second « lancement à froid » du même processus (activité refermée puis rouverte) ne reprend rien.
            assertFalse(stack.resumeOnLaunch(gate, coldStart = true) { visit.also { looked = true } })
            assertEquals(listOf(Route.Lists), stack)
            assertFalse(looked)
        }

    @Test
    fun aRestoredActivityDoesNotResumeEvenOnItsFirstComposition() =
        runTest {
            // Mort du processus : nouveau conteneur, mais l'activité revient avec son état et sa pile.
            val gate = LaunchResume()
            val stack = stack(Route.Lists)
            assertFalse(stack.resumeOnLaunch(gate, coldStart = false) { visit })
            assertEquals(1, stack.size)
        }

    @Test
    fun withoutAnOpenVisitNothingIsResumed() =
        runTest {
            val stack = stack(Route.Lists)
            assertFalse(stack.resumeOnLaunch(LaunchResume(), coldStart = true) { null })
            assertEquals(1, stack.size)
        }

    @Test
    fun anOpenVisitIsOnlyPushedOnAFreshStack() {
        val navigated = stack(Route.Lists, Route.ListDetail("b"))
        assertFalse(navigated.resumeShopping(visit))
        assertEquals(2, navigated.size)
    }

    @Test
    fun theEndOfShoppingReplacesItWithTheSummary() {
        val shopping = Route.Shopping("a", "s1")
        val stack = stack(Route.Lists, Route.ListDetail("a"), shopping)
        val summary = ShoppingSummary(3, 12, "Carrefour", RouteKnowledge.Learning(40), "v1")
        assertTrue(stack.finishShopping(shopping.slot, summary))
        val end = stack.last() as Route.ShoppingSummary
        assertEquals(summary, end.summary)
        assertEquals("a", end.listId)
        // Slot neuf : l'entrée du mode courses quitte la pile, son ViewModel avec (#54, M5).
        assertNotEquals(shopping.slot, end.slot)
        // Pas de retour en mode courses : le résumé a pris sa place, et un second événement ne fait rien.
        assertEquals(3, stack.size)
        assertFalse(stack.finishShopping(shopping.slot, summary))
        assertTrue(stack.popIfTop(end.slot))
        assertEquals(Route.ListDetail::class, stack.last()::class)
        assertFalse(stack.popIfTop(end.slot))
    }

    @Test
    fun aRemapFollowsTheSummaryList() {
        val end = Route.ShoppingSummary("old", ShoppingSummary(1, 1, null, RouteKnowledge.NoStore))
        val stack = stack(Route.Lists, Route.ListDetail("old"), end)
        stack.applyRemap(IdentifierRemap(mapOf("old" to "new")))
        assertEquals("new", (stack.last() as Route.ShoppingSummary).listId)
    }

    @Test
    fun aRemapFollowsTheSummaryVisitAndKeepsTheScreen() {
        val end = Route.ShoppingSummary("old", ShoppingSummary(2, 5, "Carrefour", RouteKnowledge.Unknown, "v-old"))
        val stack = stack(Route.Lists, Route.ListDetail("old"), end)
        stack.applyRemap(IdentifierRemap(mapOf("old" to "new", "v-old" to "v-new")))
        val moved = stack.last() as Route.ShoppingSummary
        assertEquals("v-new", moved.summary.visitId)
        assertEquals(end.slot, moved.slot)
    }

    // region Lien de la Live Update

    private val linked = ResumableVisit("a", "s1", "v1")

    @Test
    fun aLiveUpdateLinkOpensListsThenShopping() {
        val stack = stack(Route.Lists, Route.ListDetail("b"))

        assertTrue(stack.openLinkedShopping(linked))

        assertEquals(2, stack.size)
        assertEquals(Route.Lists, stack.first())
        val shopping = stack.last() as Route.Shopping
        assertEquals("a", shopping.listId)
        assertEquals("s1", shopping.storeId)
    }

    @Test
    fun aLiveUpdateLinkToTheShoppingScreenAlreadyOpenChangesNothing() {
        val open = Route.Shopping("a", "s1")
        val stack = stack(Route.Lists, Route.ListDetail("a"), open)

        assertFalse(stack.openLinkedShopping(linked))

        // Même écran, même slot : son état et son modèle sont gardés.
        assertEquals(
            listOf(Route.Lists, Route.ListDetail("a").copy(slot = (stack[1] as Route.ListDetail).slot), open),
            stack,
        )
    }

    @Test
    fun aLiveUpdateLinkReplacesTheSummaryOfAnotherVisit() {
        val summary = ShoppingSummary(3, 12, "Carrefour", RouteKnowledge.Unknown, "v0")
        val stack = stack(Route.Lists, Route.ListDetail("b"), Route.ShoppingSummary("b", summary))

        assertTrue(stack.openLinkedShopping(linked))

        assertEquals(listOf("Lists", "Shopping"), stack.map { it::class.simpleName })
    }

    // endregion
}
