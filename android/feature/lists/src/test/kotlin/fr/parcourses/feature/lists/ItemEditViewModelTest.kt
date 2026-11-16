package fr.parcourses.feature.lists

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ItemEditTarget
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

// Panneau de l'article, saisie sur un article existant et astuce de l'écran Liste (#110).
@RunWith(AndroidJUnit4::class)
class ItemEditViewModelTest : ListsTest() {
    private fun ListDetailUiState.rows() = sections.flatMap { it.items }

    private fun ListDetailUiState.row(label: String) = rows().single { it.label == label }

    // region Saisie sur un article existant

    @Test
    fun anEntryWithAQuantityUpdatesTheSameUncheckedItem() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val milk = lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            model.uiState.await { it.isLoaded && it.rows().size == 1 }

            model.type("lait x3")
            model.submit()

            model.uiState.await { it.rows().singleOrNull()?.quantity == "3" }
            assertEquals("", model.input.text.toString())
            val stored = lists.items(id).single()
            assertEquals(milk.id, stored.id)
            // Le libellé de l'article ne change pas.
            assertEquals("lait", stored.label)
        }

    @Test
    fun anEntryWithoutQuantityOrOnACheckedItemIsAdded() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val milk = lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            model.uiState.await { it.isLoaded && it.rows().size == 1 }

            model.type("lait")
            model.submit()
            model.uiState.await { it.rows().size == 2 }

            lists.setChecked(milk.id, clock, clock)
            val second = lists.items(id).last()
            lists.setChecked(second.id, clock, clock)
            model.type("2 lait")
            model.submit()
            model.uiState.await { it.rows().size == 3 }
            assertEquals("2", lists.items(id).last().quantity)
        }

    // endregion

    // region Panneau de l'article

    @Test
    fun aLongPressOpensTheSheetAndSavingWritesLabelAndQuantity() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            lists.addItem(id, "lait", "lait", "1", PRODUCT, "dairy", clock)
            val model = detailModel(id)
            val milk = model.uiState.await { it.rows().size == 1 }.row("lait")

            model.openItemEditor(milk)
            val target = model.uiState.await { it.editing != null }.editing
            assertEquals(ItemEditTarget(milk.id, "lait", "1"), target)

            model.saveItem(" pommes ", "1,5 kg")
            val state = model.uiState.await { s -> s.rows().any { it.label == "pommes" } }
            val apples = state.row("pommes")
            assertEquals("1,5 kg", apples.quantity)
            // Reclassé comme à l'ajout : l'article change de rayon.
            assertEquals("produce", apples.categoryId)
            assertEquals(listOf("produce"), state.sections.map { it.categoryId })
            assertNull(lists.items(id).single().productId)

            // Le panneau se range de lui-même après « Enregistrer ».
            model.closeItemEditor()
            assertNull(model.uiState.await { it.editing == null }.editing)
        }

    @Test
    fun closingTheSheetWritesNothing() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            val milk = model.uiState.await { it.rows().size == 1 }.row("lait")
            val wakeUpsBefore = wakeUps

            model.openItemEditor(milk)
            model.uiState.await { it.editing != null }
            model.closeItemEditor()
            model.uiState.await { it.editing == null }
            // Fermé sans enregistrer : un appui sur « Enregistrer » arrivé après ne retrouve plus d'article.
            model.saveItem("pain", "3")
            assertEquals(wakeUpsBefore, wakeUps)
            assertEquals("lait", lists.items(id).single().label)
        }

    @Test
    fun anUnchangedSheetWritesNothing() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            val milk = model.uiState.await { it.rows().size == 1 }.row("lait")
            val wakeUpsBefore = wakeUps

            model.openItemEditor(milk)
            model.uiState.await { it.editing != null }
            model.saveItem("lait ", " 1 ")
            model.saveItem("   ", "4")
            model.closeItemEditor()
            // Les écritures passent une à une : une fois l'ajout suivant visible, les enregistrements d'avant sont faits.
            model.type("pain")
            model.submit()
            model.uiState.await { it.rows().size == 2 }
            assertEquals(wakeUpsBefore + 1, wakeUps)
            assertEquals("1", lists.items(id).first { it.label == "lait" }.quantity)
        }

    @Test
    fun theSheetIsForgottenWhenItsItemDisappears() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val milk = lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            model.openItemEditor(model.uiState.await { it.rows().size == 1 }.row("lait"))
            model.uiState.await { it.editing != null }

            lists.deleteItem(milk.id, clock)
            model.uiState.await { it.rows().isEmpty() && it.editing == null }
            // Le même article revenu (annulation, synchro) ne rouvre pas le panneau de lui-même.
            db.items().upsert(milk)
            assertNull(model.uiState.await { it.rows().size == 1 }.editing)
        }

    @Test
    fun aRemoteRenameWhileTheSheetIsOpenIsKept() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            val milk = lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            val model = detailModel(id)
            model.openItemEditor(model.uiState.await { it.rows().size == 1 }.row("lait"))
            model.uiState.await { it.editing != null }

            db.items().upsert(milk.copy(label = "lait entier", normalizedName = "lait entier"))
            model.uiState.await { s -> s.rows().any { it.label == "lait entier" } }
            model.saveItem("lait", "3")

            val row =
                model.uiState
                    .await { s -> s.rows().any { it.quantity == "3" } }
                    .rows()
                    .single()
            assertEquals("lait entier", row.label)
        }

    @Test
    fun aReaderCannotOpenTheSheet() =
        runBlocking {
            val id = lists.createList("Courses", clock).id
            lists.addItem(id, "lait", "lait", "1", null, "dairy", clock)
            db.lists().setRole(id, ListRole.Viewer)
            val model = detailModel(id)
            val milk = model.uiState.await { it.isLoaded && it.sharing.role == ListRole.Viewer }.row("lait")

            model.openItemEditor(milk)
            model.saveItem("pain", "3")
            assertNull(model.uiState.value.editing)
            assertEquals("lait", lists.items(id).single().label)
        }

    // endregion

    // region Astuce

    @Test
    fun theTipAppearsAfterTheFirstAddedItemAndGoesAwayWhenClosed() =
        runBlocking {
            val tip = InMemoryQuantityTipMemory()
            val id = lists.createList("Courses", clock).id
            val model = detailModel(id, quantityTip = tip)
            assertFalse(model.uiState.await { it.isLoaded }.showsQuantityTip)

            model.type("lait")
            model.submit()
            assertTrue(model.uiState.await { it.showsQuantityTip }.showsQuantityTip)

            model.dismissQuantityTip()
            assertFalse(model.uiState.await { !it.showsQuantityTip }.showsQuantityTip)
            assertFalse(tip.isEligible.value)
        }

    @Test
    fun openingTheSheetRetiresTheTipForGood() =
        runBlocking {
            val tip = InMemoryQuantityTipMemory(itemAdded = true)
            val id = lists.createList("Courses", clock).id
            lists.addItem(id, "lait", "lait", null, null, "dairy", clock)
            val model = detailModel(id, quantityTip = tip)
            val milk = model.uiState.await { it.showsQuantityTip }.row("lait")

            model.openItemEditor(milk)
            model.uiState.await { !it.showsQuantityTip }
            tip.itemAdded()
            assertFalse(tip.isEligible.value)
        }

    @Test
    fun theTipNeedsItemsAndAnEditor() =
        runBlocking {
            val tip = InMemoryQuantityTipMemory(itemAdded = true)
            val empty = lists.createList("Vide", clock).id
            assertFalse(detailModel(empty, quantityTip = tip).uiState.await { it.isLoaded }.showsQuantityTip)

            val shared = lists.createList("Partagée", clock).id
            lists.addItem(shared, "lait", "lait", null, null, "dairy", clock)
            db.lists().setRole(shared, ListRole.Viewer)
            val reader = detailModel(shared, quantityTip = tip)
            assertFalse(
                reader.uiState
                    .await { it.isLoaded && it.sharing.role == ListRole.Viewer }
                    .showsQuantityTip,
            )
        }

    // endregion

    private companion object {
        const val PRODUCT = "11111111-1111-4111-8111-111111111111"
    }
}
