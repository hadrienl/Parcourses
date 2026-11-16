package fr.parcourses.feature.shopping

import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ItemEditTarget
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.minutes

// Mode courses (#110) : « Quantité » du menu d'appui long et saisie sur un article existant.
@RunWith(AndroidJUnit4::class)
class ShoppingItemEditTest : ShoppingTest() {
    private suspend fun groceries() =
        newList(
            Triple("lait", "dairy", null),
            Triple("pain", "bakery", null),
            Triple("pommes", "produce", null),
        )

    // region Panneau de l'article

    @Test
    fun quantityOpensTheSheetAndSavingUpdatesTheRow() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val milk = started(model).row("lait")

            model.openItemEditor(milk)
            runCurrent()
            assertEquals(ItemEditTarget(milk.id, "lait", null), model.uiState.value.editing)

            model.saveItem("lait", "2")
            runCurrent()
            assertEquals(
                "2",
                model.uiState.value
                    .row("lait")
                    .quantity,
            )
            assertEquals("2", lists.items(listId).first { it.id == milk.id }.quantity)

            model.closeItemEditor()
            runCurrent()
            assertNull(model.uiState.value.editing)
        }

    @Test
    fun aNewLabelChangesTheAisleAndTheListIsSortedAgain() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            // Ordre générique : fruits, boulangerie, crèmerie.
            assertEquals(listOf("pommes", "pain", "lait"), model.uiState.value.labels())

            model.openItemEditor(model.uiState.value.row("lait"))
            runCurrent()
            model.saveItem("bananes", "")
            runCurrent()
            after(600)

            val state = model.uiState.value
            assertEquals("produce", state.row("bananes").aisleId)
            assertEquals(listOf("produce", "bakery"), state.sections.map { it.aisleId })
            assertEquals(
                setOf("pommes", "bananes"),
                state.sections
                    .first()
                    .rows
                    .map { it.label }
                    .toSet(),
            )
        }

    @Test
    fun closingTheSheetWritesNothing() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val milk = started(model).row("lait")
            val before = db.outbox().pending().size

            model.openItemEditor(milk)
            runCurrent()
            model.closeItemEditor()
            model.saveItem("beurre", "3")
            runCurrent()
            assertEquals(before, db.outbox().pending().size)
            assertEquals("lait", lists.items(listId).first { it.id == milk.id }.label)
        }

    @Test
    fun theSheetIsForgottenWhenTheRowIsNoLongerToTake() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val milk = started(model).row("lait")
            model.openItemEditor(milk)
            runCurrent()

            // Coché (ici ou par un autre membre) : plus rien à modifier en route.
            model.toggle(milk)
            runCurrent()
            assertNull(model.uiState.value.editing)
            model.toggle(model.uiState.value.row("lait"))
            after(600)
            assertNull(model.uiState.value.editing)
        }

    /** Courses expirées, panneau ouvert : il se ferme, la feuille « articles restants » prend la place. */
    @Test
    fun theSheetIsForgottenWhenShoppingExpires() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val state = started(model)
            model.toggle(state.row("pommes"))
            runCurrent()
            model.openItemEditor(model.uiState.value.row("lait"))
            runCurrent()
            assertEquals("lait", model.uiState.value.editing?.label)

            offset += 46.minutes
            model.foregrounded()
            runCurrent()
            assertTrue(model.uiState.value.expired)
            assertNull(model.uiState.value.editing)
        }

    @Test
    fun aCheckedRowHasNoSheet() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            val milk = started(model).row("lait")
            model.openItemEditor(milk.copy(isChecked = true))
            runCurrent()
            assertNull(model.uiState.value.editing)
        }

    // endregion

    // region Saisie sur un article existant

    @Test
    fun anEntryWithAQuantityUpdatesTheItemAndHighlightsItWithoutSorting() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            started(model)
            val order = model.uiState.value.labels()

            model.input.setTextAndPlaceCursorAtEnd("lait x3")
            model.submit()
            runCurrent()

            val state = model.uiState.value
            assertEquals(3, lists.items(listId).size)
            assertEquals("3", state.row("lait").quantity)
            assertEquals("lait", lists.items(listId).first { it.id == items[0].id }.label)
            assertEquals(items[0].id, state.highlightedItemId)
            assertEquals("", model.input.text.toString())
            assertEquals(order, state.labels())
        }

    @Test
    fun aNotFoundItemIsAValidTarget() =
        runTest(main) {
            val (listId, items) = groceries()
            val model = model(listId)
            started(model)
            model.markNotFound(model.uiState.value.row("lait"))
            runCurrent()

            model.input.setTextAndPlaceCursorAtEnd("2 lait")
            model.submit()
            runCurrent()

            assertEquals(3, lists.items(listId).size)
            assertEquals("2", lists.items(listId).first { it.id == items[0].id }.quantity)
            assertEquals(
                "2",
                model.uiState.value.notFound
                    .single()
                    .quantity,
            )
        }

    @Test
    fun aCheckedItemIsNotATargetAndAnEntryWithoutQuantityIsAdded() =
        runTest(main) {
            val (listId, _) = groceries()
            val model = model(listId)
            started(model)
            model.toggle(model.uiState.value.row("lait"))
            runCurrent()

            model.input.setTextAndPlaceCursorAtEnd("2 lait")
            model.submit()
            runCurrent()
            assertEquals(4, lists.items(listId).size)

            model.input.setTextAndPlaceCursorAtEnd("pain")
            model.submit()
            runCurrent()
            assertEquals(5, lists.items(listId).size)
        }

    // endregion
}
