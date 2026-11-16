package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ItemEditSheet
import fr.parcourses.core.designsystem.ItemEditTarget
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_CLEAR
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_DECREASE
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_INCREASE
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_LABEL
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_QUANTITY
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_SAVE
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_SHEET
import fr.parcourses.core.designsystem.TAG_ITEM_EDIT_UNIT
import fr.parcourses.core.model.ListRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

// Écran Liste (#110) : quantité sous le nom, appui long, panneau de l'article, astuce.
@RunWith(AndroidJUnit4::class)
class ItemEditScreenTest : ListsTest() {
    @get:Rule
    val rule = createComposeRule()

    private val milk = ItemRow("1", "lait", "500 g", "dairy", "lait", isChecked = false)
    private val sections = listOf(ItemSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk)))
    private val edited = mutableListOf<String>()
    private val saved = mutableListOf<Pair<String, String>>()
    private var closed = 0
    private var tipDismissed = 0

    private fun showList(state: ListDetailUiState) {
        rule.setContent {
            ParcoursesTheme {
                ListDetailScreen(
                    state = state,
                    input = TextFieldState(),
                    onSubmit = {},
                    onSuggestion = {},
                    onToggle = {},
                    onDelete = {},
                    onBack = {},
                    onDismissError = {},
                    itemEditing =
                        ItemEditing(
                            onEdit = { edited += it.id },
                            onSave = { label, quantity -> saved += label to quantity },
                            onClose = { closed++ },
                            onDismissTip = { tipDismissed++ },
                        ),
                )
            }
        }
    }

    private fun showSheet(target: ItemEditTarget) {
        rule.setContent {
            ParcoursesTheme {
                var open by mutableStateOf(true)
                if (open) {
                    ItemEditSheet(
                        target,
                        onSave = { label, quantity -> saved += label to quantity },
                        onDismiss = {
                            closed++
                            open = false
                        },
                    )
                }
            }
        }
    }

    private fun quantityField() = rule.onNodeWithTag(TAG_ITEM_EDIT_QUANTITY)

    // region Ligne

    @Test
    fun theQuantityIsShownUnderTheNameAndReadWithIt() {
        showList(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        val name = rule.onNodeWithText("lait", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        val quantity = rule.onNodeWithText("500 g", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        assertTrue("quantité sous le nom", quantity.top >= name.bottom)
        rule.onNodeWithContentDescription("lait, 500 g").assertExists()
    }

    @Test
    fun aLongPressOpensTheItemSheetAndATapStillChecks() {
        showList(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        val row = rule.onNodeWithContentDescription("lait, 500 g")
        assertEquals(
            "Modifier la quantité",
            row.fetchSemanticsNode().config[SemanticsActions.OnLongClick].label,
        )
        row.performTouchInput { longClick() }
        assertEquals(listOf("1"), edited)

        val action =
            row.fetchSemanticsNode().config[SemanticsActions.CustomActions].single {
                it.label == "Modifier la quantité"
            }
        rule.runOnUiThread { action.action() }
        assertEquals(listOf("1", "1"), edited)
    }

    @Test
    fun aReaderHasNoLongPress() {
        showList(
            ListDetailUiState(
                name = "Semaine",
                sections = sections,
                isLoaded = true,
                sharing = ListSharingUi(role = ListRole.Viewer),
            ),
        )
        val row = rule.onNodeWithContentDescription("lait, 500 g")
        assertTrue(SemanticsActions.OnLongClick !in row.fetchSemanticsNode().config)
        row.performTouchInput { longClick() }
        assertTrue(edited.isEmpty())
    }

    @Test
    fun theStateSheetIsShownWhenEditing() {
        showList(
            ListDetailUiState(
                name = "Semaine",
                sections = sections,
                isLoaded = true,
                editing = ItemEditTarget("1", "lait", "500 g"),
            ),
        )
        rule.onNodeWithTag(TAG_ITEM_EDIT_SHEET).assertExists()
        rule.onNodeWithText("Article").assertExists()
    }

    // endregion

    // region Astuce

    @Test
    fun theTipIsShownAboveTheItemsAndCanBeClosed() {
        showList(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true, showsQuantityTip = true))
        rule.onNodeWithText("Maintiens un article pour changer sa quantité").assertExists()
        rule.onNodeWithContentDescription("Fermer l'astuce").performClick()
        assertEquals(1, tipDismissed)
    }

    @Test
    fun theTipIsHiddenByDefault() {
        showList(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        rule.onNodeWithTag(TAG_QUANTITY_TIP).assertDoesNotExist()
    }

    // endregion

    // region Panneau

    @Test
    fun plusAndMinusStepTheLeadingNumber() {
        showSheet(ItemEditTarget("1", "lait", "500 g"))
        rule.onNodeWithContentDescription("Augmenter la quantité").performClick()
        quantityField().assertTextContains("600 g")
        rule.onNodeWithContentDescription("Diminuer la quantité").performClick()
        rule.onNodeWithContentDescription("Diminuer la quantité").performClick()
        quantityField().assertTextContains("400 g")
    }

    @Test
    fun minusIsDisabledAtOneAndBothAreDisabledWithoutANumber() {
        showSheet(ItemEditTarget("1", "lait", "1"))
        rule.onNodeWithTag(TAG_ITEM_EDIT_DECREASE).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_ITEM_EDIT_INCREASE).assertIsEnabled()
        quantityField().performTextClearance()
        quantityField().performTextInput("un peu")
        rule.onNodeWithTag(TAG_ITEM_EDIT_DECREASE).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_ITEM_EDIT_INCREASE).assertIsNotEnabled()
        rule.onNodeWithTag("$TAG_ITEM_EDIT_UNIT-g").assertIsNotEnabled()
    }

    @Test
    fun withoutQuantityPlusGivesTwo() {
        showSheet(ItemEditTarget("1", "lait", null))
        rule.onNodeWithTag(TAG_ITEM_EDIT_DECREASE).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_ITEM_EDIT_CLEAR).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_ITEM_EDIT_INCREASE).performClick()
        quantityField().assertTextContains("2")
    }

    @Test
    fun unitShortcutsToggleTheUnit() {
        showSheet(ItemEditTarget("1", "farine", "2"))
        val kilos = rule.onNodeWithContentDescription("kilos")
        kilos.assertIsNotSelected().performClick()
        quantityField().assertTextContains("2 kg")
        kilos.assertIsSelected()
        rule.onNodeWithContentDescription("grammes").performClick()
        quantityField().assertTextContains("2 g")
        rule.onNodeWithContentDescription("grammes").performClick()
        quantityField().assertTextContains("2")
        rule.onNodeWithContentDescription("litres").assertIsNotSelected()
    }

    @Test
    fun clearEmptiesTheQuantity() {
        showSheet(ItemEditTarget("1", "lait", "500 g"))
        rule.onNodeWithText("Effacer la quantité").performClick()
        val text = quantityField().fetchSemanticsNode().config[SemanticsProperties.EditableText].text
        assertEquals("", text)
        rule.onNodeWithTag(TAG_ITEM_EDIT_CLEAR).assertIsNotEnabled()
    }

    @Test
    fun saveHandsBothFieldsAndCloses() {
        showSheet(ItemEditTarget("1", "lait", "1"))
        rule.onNodeWithTag(TAG_ITEM_EDIT_LABEL).performTextClearance()
        rule.onNodeWithTag(TAG_ITEM_EDIT_SAVE).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_ITEM_EDIT_LABEL).performTextInput("lait d'avoine")
        rule.onNodeWithTag(TAG_ITEM_EDIT_INCREASE).performClick()
        rule.onNodeWithTag(TAG_ITEM_EDIT_SAVE).assertIsEnabled().performClick()
        rule.waitForIdle()
        assertEquals(listOf("lait d'avoine" to "2"), saved)
        assertEquals(1, closed)
    }

    @Test
    fun cancelWritesNothing() {
        showSheet(ItemEditTarget("1", "lait", "1"))
        rule.onNodeWithTag(TAG_ITEM_EDIT_INCREASE).performClick()
        rule.onNodeWithText("Annuler").performClick()
        rule.waitForIdle()
        assertTrue(saved.isEmpty())
        assertEquals(1, closed)
    }

    // endregion
}
