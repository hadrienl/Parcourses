package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.storepicker.StorePickerOutcome
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
