package fr.parcourses.feature.shopping

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.database.entity.ListParticipantEntity
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Mode courses à deux (#87 §7) : un article coché par un autre membre arrive par la descente et glisse au panier avec
 * son initiale, sans coche dans ma visite ; une liste retirée pendant les courses les arrête.
 */
@RunWith(AndroidJUnit4::class)
class SharedShoppingTest : ShoppingTest() {
    private val notices = MutableStateFlow<List<AccessChange>>(emptyList())

    private fun sharedModel(listId: String) =
        tracked {
            ShoppingViewModel(
                listId = listId,
                storeId = storeId,
                deps =
                    ShoppingDependencies(
                        lists = lists,
                        visits = visits,
                        stores = stores,
                        categories = RoomCategoryRepository(db),
                        analyzer = analyzer,
                        cache = GraphSnapshotCache(graphs, gateway, clock),
                        participants = { id ->
                            listOf(
                                ListParticipantEntity(id, OWNER, "Hadrien", ListRole.Owner, isMe = true),
                                ListParticipantEntity(id, LEA, "Léa", ListRole.Editor, isMe = false),
                            )
                        },
                        accessNotices = notices,
                    ),
                now = clock,
                computation = main,
            )
        }

    @Test
    fun anItemCheckedByAnotherMemberGoesToTheBasketWithoutAVisitCheck() =
        runTest(main) {
            val (listId, items) = newList(Triple("lait", "dairy", null), Triple("pain", "bakery", null))
            val model = sharedModel(listId)
            started(model)
            val milk = items.first()

            // La descente apporte la coche de Léa.
            db.items().upsert(checkNotNull(db.items().get(milk.id)).copy(checkedAt = clock(), updatedBy = LEA))
            runCurrent()
            after(SETTLE_MS)

            val state = model.uiState.value
            val basket = state.basket.single()
            assertEquals("lait", basket.label)
            assertEquals("L", basket.checkedBy)
            assertEquals("Léa", basket.checkedByName)
            assertEquals(listOf("pain"), state.labels())
            // Aucune coche dans ma visite : elle reste celle de Léa.
            assertTrue(db.checks().getAll().isEmpty())
            assertNull(state.undo)
        }

    @Test
    fun myOwnCheckCarriesNoInitial() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", null))
            val model = sharedModel(listId)
            val state = started(model)
            model.toggle(state.row("lait"))
            runCurrent()
            after(SETTLE_MS)
            assertNull(
                model.uiState.value.basket
                    .single()
                    .checkedBy,
            )
            assertEquals(1, db.checks().getAll().size)
        }

    @Test
    fun aListNoLongerSharedStopsTheShopping() =
        runTest(main) {
            val (listId, _) = newList(Triple("lait", "dairy", null))
            val model = sharedModel(listId)
            started(model)
            assertFalse(model.uiState.value.accessLost)

            notices.value = listOf(AccessChange.Removed("autre", "Autre"))
            runCurrent()
            assertFalse(model.uiState.value.accessLost)

            notices.value = listOf(AccessChange.Removed(listId, "Courses"))
            runCurrent()
            assertTrue(model.uiState.value.accessLost)
        }

    private companion object {
        const val OWNER = "11111111-1111-4111-8111-111111111111"
        const val LEA = "22222222-2222-4222-8222-222222222222"
        const val SETTLE_MS = 2_000L
    }
}
