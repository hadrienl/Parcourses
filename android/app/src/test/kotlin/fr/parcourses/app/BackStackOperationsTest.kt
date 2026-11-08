package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.storepicker.StorePickerOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun anOpenVisitIsResumedOnlyOnAFreshStack() {
        val visit = ResumableVisit("a", "s1")
        val fresh = stack(Route.Lists)
        assertTrue(fresh.resumeShopping(visit))
        assertEquals(listOf("Lists", "ListDetail", "Shopping"), fresh.map { it::class.simpleName })

        val navigated = stack(Route.Lists, Route.ListDetail("b"))
        assertFalse(navigated.resumeShopping(visit))
        assertEquals(2, navigated.size)
    }
}
