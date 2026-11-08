package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListDetailScreenTest : ListsTest() {
    @get:Rule
    val rule = createComposeRule()

    private val toggled = mutableListOf<String>()
    private val deleted = mutableListOf<String>()
    private val suggested = mutableListOf<String>()
    private var submitted = 0
    private var backs = 0
    private var shopping = 0

    private val milk = ItemRow("1", "laits demi-écrémé", "2", "dairy", "lait demi ecreme", isChecked = false)
    private val bread = ItemRow("2", "pain", null, "bakery", "pain", isChecked = true)
    private val sections =
        listOf(
            ItemSection("bakery", "Boulangerie, pâtisserie", listOf(bread)),
            ItemSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk)),
        )

    private fun show(
        state: ListDetailUiState,
        input: TextFieldState = TextFieldState(),
        withShopping: Boolean = false,
    ) {
        rule.setContent {
            ParcoursesTheme {
                ListDetailScreen(
                    state = state,
                    input = input,
                    onSubmit = { submitted++ },
                    onSuggestion = { suggested += it.id },
                    onToggle = { toggled += it.id },
                    onDelete = { deleted += it.id },
                    onBack = { backs++ },
                    onDismissError = {},
                    onStartShopping = if (withShopping) ({ shopping++ }) else null,
                )
            }
        }
    }

    @Test
    fun itemsAreGroupedByAisleWithHeadings() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        rule.onNodeWithText("Semaine").assertExists()
        rule.onNodeWithText("Boulangerie, pâtisserie").assertExists()
        rule.onNodeWithText("Crèmerie, œufs, ultra-frais").assertExists()
        rule.onNodeWithText("laits demi-écrémé").assertExists()
        rule.onNodeWithText("2").assertExists()
    }

    @Test
    fun theCheckedStateIsAnnouncedWithoutColor() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        rule.onNodeWithContentDescription("laits demi-écrémé, 2").assert(hasStateDescription("non coché"))
        rule.onNodeWithContentDescription("pain").assert(hasStateDescription("coché"))
    }

    @Test
    fun tappingARowTogglesIt() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        rule.onNodeWithContentDescription("laits demi-écrémé, 2").performClick()
        assertEquals(listOf("1"), toggled)
    }

    @Test
    fun deletionIsAnAccessibilityActionAndAButton() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        val actions =
            rule
                .onNodeWithContentDescription(
                    "pain",
                ).fetchSemanticsNode()
                .config[SemanticsActions.CustomActions]
        assertEquals("Supprimer", actions.single().label)
        rule.runOnUiThread { actions.single().action() }
        assertEquals(listOf("2"), deleted)
    }

    @Test
    fun anEmptyListInvitesToAddAnItem() {
        show(ListDetailUiState(name = "Semaine", isLoaded = true))
        rule.onNodeWithText("Liste vide").assertExists()
        rule.onNodeWithTag(TAG_QUICK_ENTRY).assertExists()
    }

    @Test
    fun nothingIsAnnouncedEmptyBeforeTheFirstRead() {
        show(ListDetailUiState(isLoaded = false))
        rule.onNodeWithText("Liste vide").assertDoesNotExist()
    }

    @Test
    fun aMissingListHidesTheDock() {
        show(ListDetailUiState(isLoaded = true, isMissing = true))
        rule.onNodeWithText("Liste introuvable").assertExists()
        rule.onNodeWithTag(TAG_QUICK_ENTRY).assertDoesNotExist()
        rule.onNodeWithTag(TAG_SHOP).assertDoesNotExist()
    }

    @Test
    fun theAddButtonNeedsSomeText() {
        val input = TextFieldState()
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true), input)
        rule.onNodeWithTag(TAG_ADD).assertIsNotEnabled()
        rule.onNodeWithTag(TAG_QUICK_ENTRY).performTextInput("lait")
        rule.onNodeWithTag(TAG_ADD).assertIsEnabled().performClick()
        assertEquals(1, submitted)
    }

    @Test
    fun suggestionsAreChipsThatAddTheProposal() {
        val suggestion = ItemSuggestion("tomate", "tomates", null, "produce", 2, null)
        show(
            ListDetailUiState(name = "Semaine", sections = sections, suggestions = listOf(suggestion), isLoaded = true),
        )
        rule.onNodeWithContentDescription("Ajouter tomates").performClick()
        assertEquals(listOf("tomate"), suggested)
    }

    @Test
    fun shoppingIsOfferedOnlyWhenWiredAndTheListIsNotEmpty() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true), withShopping = true)
        rule.onNodeWithTag(TAG_SHOP).assertIsEnabled().performClick()
        assertEquals(1, shopping)
    }

    @Test
    fun backIsReachable() {
        show(ListDetailUiState(name = "Semaine", sections = sections, isLoaded = true))
        rule.onNodeWithContentDescription("Retour").performClick()
        assertEquals(1, backs)
    }

    @Test
    fun theScreenWorksEndToEndWithTheRealModel() {
        val id = kotlinx.coroutines.runBlocking { lists.createList("Semaine", clock).id }
        val model = detailModel(id)
        rule.setContent {
            ParcoursesTheme { ListDetailRoute(viewModel = model, onBack = {}) }
        }
        rule.waitUntil(5_000) { model.uiState.value.isLoaded }
        rule.onNodeWithText("Liste vide").assertExists()

        rule.onNodeWithTag(TAG_QUICK_ENTRY).performTextInput("2 laits demi-écrémé")
        rule.onNodeWithTag(TAG_ADD).performClick()
        rule.waitUntil(5_000) {
            model.uiState.value.sections
                .isNotEmpty()
        }

        rule.onNodeWithText("Crèmerie, œufs, ultra-frais").assertExists()
        rule.onNodeWithContentDescription("laits demi-écrémé, 2").performClick()
        rule.waitUntil(5_000) {
            model.uiState.value.sections
                .firstOrNull()
                ?.items
                ?.firstOrNull()
                ?.isChecked == true
        }
        rule.onNodeWithContentDescription("laits demi-écrémé, 2").assert(hasStateDescription("coché"))
        // La saisie est vidée après l'ajout, prête pour le suivant.
        assertEquals("", model.input.text.toString())
        model.input.setTextAndPlaceCursorAtEnd("")
    }
}
