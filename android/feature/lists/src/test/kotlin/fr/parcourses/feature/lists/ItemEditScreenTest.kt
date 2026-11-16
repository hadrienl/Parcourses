package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
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

// Écran Liste (#110) : appui long, panneau de l'article, astuce.
@RunWith(AndroidJUnit4::class)
class ItemEditScreenTest : ListsTest() {
    @get:Rule
    val rule = createComposeRule()

    private val milk = ItemRow("1", "lait", "500 g", "dairy", "lait", isChecked = false)
    private val sections = listOf(ItemSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk)))
    private val edited = mutableListOf<String>()
    private val toggled = mutableListOf<String>()
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
                    onToggle = { toggled += it.id },
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
                var open by remember { mutableStateOf(true) }
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

    /**
     * Pendant l'appui (#110), seuls la case et le texte s'enfoncent : la ligne, qui porte le fil du ticket (`.thread`),
     * garde exactement sa place, et le contenu reste collé à son bord gauche, côté fil.
     */
    @Test
    fun aPressSinksTheContentButNotTheThread() {
        showList(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        val row = rule.onNodeWithContentDescription("lait, 500 g")
        val content = rule.onNodeWithTag(TAG_ITEM_CONTENT, useUnmergedTree = true)
        val rowAtRest = row.fetchSemanticsNode().boundsInRoot
        val contentAtRest = content.fetchSemanticsNode().boundsInRoot

        rule.mainClock.autoAdvance = false
        row.performTouchInput { down(center) }
        rule.mainClock.advanceTimeBy(PRESS_MILLIS)
        val rowPressed = row.fetchSemanticsNode().boundsInRoot
        val contentPressed = content.fetchSemanticsNode().boundsInRoot
        row.performTouchInput { up() }
        rule.mainClock.autoAdvance = true

        assertEquals(rowAtRest, rowPressed)
        assertTrue("le contenu s'enfonce", contentPressed.width < contentAtRest.width)
        assertEquals(contentAtRest.left, contentPressed.left, 0.5f)
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

        // TalkBack : l'action « Modifier la quantité » est l'appui long libellé, une seule fois.
        val longClick = row.fetchSemanticsNode().config[SemanticsActions.OnLongClick]
        rule.runOnUiThread { longClick.action?.invoke() }
        assertEquals(listOf("1", "1"), edited)
        assertTrue(
            row.fetchSemanticsNode().config[SemanticsActions.CustomActions].none {
                it.label == "Modifier la quantité"
            },
        )

        // Toucher coche toujours, sans ouvrir le panneau.
        row.performClick()
        assertEquals(listOf("1"), toggled)
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

    /**
     * Limite comptée en points de code, comme le serveur et iOS : un libellé de 150 emoji (300 unités UTF-16) reste
     * modifiable ; la saisie va jusqu'à 200 points de code tout juste, la suivante est refusée. Même règle pour la
     * quantité, à 50.
     */
    @Test
    fun theLimitsCountCodePoints() {
        val milk = "\uD83E\uDD5B"
        showSheet(ItemEditTarget("1", milk.repeat(150), null))
        val label = rule.onNodeWithTag(TAG_ITEM_EDIT_LABEL)
        label.performTextInput("x")
        label.performTextInput(milk.repeat(49))
        label.performTextInput("y")
        quantityField().performTextInput("1".repeat(50))
        quantityField().performTextInput("2")
        rule.onNodeWithTag(TAG_ITEM_EDIT_SAVE).performClick()
        rule.waitForIdle()
        assertEquals(milk.repeat(150) + "x" + milk.repeat(49) to "1".repeat(50), saved.single())
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

/** Durée de l'appui maintenu, sous le délai de l'appui long : le temps que la ligne s'enfonce. */
private const val PRESS_MILLIS = 300L
