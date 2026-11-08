package fr.parcourses.feature.shopping.live

import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.ListItemEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Instant

class ShoppingLiveStateTest {
    private val labels = mapOf("dairy" to "Crèmerie", "bakery" to "Boulangerie")

    private fun make(
        displayed: List<fr.parcourses.feature.shopping.ShoppingRow>,
        basket: List<fr.parcourses.feature.shopping.ShoppingRow> = emptyList(),
    ) = ShoppingLiveState.make(
        visitId = "v1",
        listId = "l1",
        listName = "Courses",
        storeName = "Carrefour",
        displayed = displayed,
        basket = basket,
        aisleLabel = labels::get,
        aisleIndex = { if (it == "bakery") 1 else 0 },
    )

    @Test
    fun theNextItemIsTheFirstDisplayedOneNotYetChecked() {
        // Une ligne juste cochée reste affichée le temps du tri : elle compte comme prise.
        val state = make(listOf(row("a", checked = true), row("b", aisle = "bakery"), row("c")))

        assertEquals("b", state.next?.id)
        assertEquals("Boulangerie", state.next?.aisleLabel)
        assertEquals(1, state.next?.aisleIndex)
        assertEquals(2, state.remaining)
        assertEquals(3, state.total)
    }

    @Test
    fun theBarStartsWithTheOldestCheckedItem() {
        // Le panier va du plus récent au plus ancien ; la ligne juste cochée est la plus récente.
        val state = make(listOf(row("c", checked = true), row("d")), basket = listOf(row("b", true), row("a", true)))

        assertEquals(listOf("a", "b", "c"), state.checked.map { it.id })
        assertEquals(listOf("d"), state.pending.map { it.id })
    }

    @Test
    fun everythingTakenLeavesNoNextItem() {
        val state = make(emptyList(), basket = listOf(row("a", true)))

        assertNull(state.next)
        assertEquals(0, state.remaining)
        assertEquals(1, state.total)
    }

    @Test
    fun labelsAreTruncatedWithoutSplittingAnEmoji() {
        val long = "x".repeat(59) + "🥛" + "y".repeat(10)
        val state =
            ShoppingLiveState.make("v1", "l1", "n".repeat(80), null, listOf(row("a").copy(label = long)), emptyList(), {
                null
            }, { 0 })

        val label = state.next!!.label
        assertEquals("x".repeat(59) + "…", label)
        assertEquals(ShoppingLiveState.MAX_LABEL_LENGTH + 1, state.listName.length)
        assertTrue(ShoppingLiveState.truncated("court") == "court")
    }

    @Test
    fun reconciliationFollowsTheDatabaseWithoutReordering() {
        val state =
            liveState(
                pending = listOf(liveItem("a"), liveItem("b"), liveItem("c"), liveItem("d")),
                checked = listOf(liveItem("z")),
            )
        val items =
            listOf(
                item("a", checkedAt = T),
                item("b"),
                item("c", notFoundAt = T),
                // `d` a disparu ; `z` a été décoché ailleurs.
                item("z"),
            )

        val fresh = state.reconciled(items)

        assertEquals(listOf("z", "b"), fresh.pending.map { it.id })
        assertEquals(listOf("a"), fresh.checked.map { it.id })
    }

    @Test
    fun anUnchangedStateIsReturnedAsIs() {
        val state = liveState(pending = listOf(liveItem("a")), checked = listOf(liveItem("b")))
        val same = state.reconciled(listOf(item("a"), item("b", checkedAt = T)))

        assertTrue(same === state)
    }

    @Test
    fun aRekeyRenamesVisitListAndItems() {
        val state = liveState(pending = listOf(liveItem("a")), checked = listOf(liveItem("b")))
        val remapped = state.remapped(IdentifierRemap(mapOf("v1" to "v2", "l1" to "l2", "a" to "a2", "b" to "b2")))

        assertEquals("v2", remapped.visitId)
        assertEquals("l2", remapped.listId)
        assertEquals(listOf("a2"), remapped.pending.map { it.id })
        assertEquals(listOf("b2"), remapped.checked.map { it.id })
    }

    @Test
    fun theStateTravelsThroughTheNotificationExtras() {
        val state = liveState(pending = listOf(liveItem("a")), checked = listOf(liveItem("b")))

        assertEquals(state, ShoppingLiveState.decode(state.encode()))
        assertNull(ShoppingLiveState.decode("{pas du json"))
        assertNull(ShoppingLiveState.decode("""{"visitId":"v1"}"""))
        assertNull(ShoppingLiveState.decode(null))
    }

    @Test
    fun deepLinksCarryALowercaseVisitId() {
        val id = "0A1B2C3D-0000-4000-8000-000000000001"
        assertEquals("parcourses://shopping/$id", LiveUpdateLinks.shopping(id))
        assertEquals(id.lowercase(), LiveUpdateLinks.visitId("parcourses://shopping/$id"))
        assertEquals(id.lowercase(), LiveUpdateLinks.visitId("parcourses://shopping/$id/"))
        assertNull(LiveUpdateLinks.visitId("parcourses://shopping/not-a-uuid"))
        assertNull(LiveUpdateLinks.visitId("https://shopping/$id"))
        assertNull(LiveUpdateLinks.visitId("parcourses://lists/$id"))
        assertNull(LiveUpdateLinks.visitId(null))
    }

    private fun item(
        id: String,
        checkedAt: Instant? = null,
        notFoundAt: Instant? = null,
    ) = ListItemEntity(
        id = id,
        listId = "l1",
        label = id,
        normalizedName = id,
        categoryId = "dairy",
        checkedAt = checkedAt,
        notFoundAt = notFoundAt,
        position = 0,
        updatedAt = T,
    )

    private companion object {
        val T: Instant = Instant.fromEpochSeconds(1_800_000_000)
    }
}
