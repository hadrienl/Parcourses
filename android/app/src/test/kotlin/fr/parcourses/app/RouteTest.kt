package fr.parcourses.app

import androidx.navigation3.runtime.NavKey
import kotlinx.serialization.PolymorphicSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

// La pile de navigation est sauvegardée telle quelle : chaque route doit survivre à un aller-retour.
class RouteTest {
    private val json = Json { serializersModule = routeConfiguration.serializersModule }
    private val serializer = PolymorphicSerializer(NavKey::class)

    private fun roundTrip(key: NavKey): NavKey = json.decodeFromString(serializer, json.encodeToString(serializer, key))

    @Test
    fun everyRouteSurvivesTheSavedState() {
        val detail = Route.ListDetail("0d3f2a6e-9d3b-4a39-b3d6-0e8a0d2d9b11")
        assertEquals(Route.Lists, roundTrip(Route.Lists))
        assertEquals(detail, roundTrip(detail))
        val picker = Route.StorePicker("0d3f2a6e-9d3b-4a39-b3d6-0e8a0d2d9b11")
        assertEquals(picker, roundTrip(picker))
    }

    @Test
    fun theSlotIdentifiesTheScreenNotTheList() {
        val detail = Route.ListDetail("a")
        // Après une reprise de compte la liste change, pas l'écran : il garde son état.
        val moved = detail.copy(listId = "b")
        assertEquals(detail.slot, moved.slot)
        assertNotEquals(detail.slot, Route.ListDetail("a").slot)
    }

    @Test
    fun theStorePickerKeepsItsScreenAcrossAnAccountRecovery() {
        val picker = Route.StorePicker("a")
        assertEquals(picker.slot, picker.copy(listId = "b").slot)
        assertNotEquals(picker.slot, Route.StorePicker("a").slot)
    }
}
