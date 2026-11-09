package fr.parcourses.feature.shopping

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasStateDescription
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "w411dp-h1400dp-xxhdpi")
@Suppress("LargeClass")
class ShoppingScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val toggled = mutableListOf<String>()
    private val notFound = mutableListOf<String>()
    private val restored = mutableListOf<String>()
    private val finished = mutableListOf<Boolean>()
    private var undone = 0
    private var submitted = 0
    private var closed = 0
    private var dismissed = 0
    private var shown = mutableListOf<Int>()

    private val apples = ShoppingRow("1", "pommes", "2", isChecked = false, aisleId = "produce")
    private val bread = ShoppingRow("2", "pain", null, isChecked = false, aisleId = "bakery")
    private val milk = ShoppingRow("3", "lait", null, isChecked = true, aisleId = "dairy")
    private val sections =
        listOf(
            ShoppingSection("produce", "Fruits et légumes", listOf(apples)),
            ShoppingSection("bakery", "Boulangerie, pâtisserie", listOf(bread)),
        )
    private val base =
        ShoppingUiState(
            isLoaded = true,
            name = "Semaine",
            storeName = "Carrefour",
            toBuy = listOf(apples, bread),
            sections = sections,
            groupsByAisle = true,
            knowledge = RouteKnowledge.Unknown,
        )

    private val announced = mutableListOf<String>()

    private fun show(
        state: ShoppingUiState = base,
        fontScale: Float = 1f,
        announceWithApi: Boolean = true,
    ) {
        val actions =
            ShoppingActions(
                onToggle = { toggled += it.id },
                onNotFound = { notFound += it.id },
                onRestore = { restored += it.id },
                onSubmit = { submitted++ },
                onUndo = { undone++ },
                onFinish = { finished += it },
                onDismissError = { dismissed++ },
                onAnnouncementShown = { shown += it },
                onClose = { closed++ },
            )
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                ParcoursesTheme {
                    ShoppingScreen(
                        state,
                        TextFieldState(),
                        actions,
                        announce = if (announceWithApi) ({ announced += it }) else null,
                    )
                }
            }
        }
    }

    private fun SemanticsNodeInteraction.customActionLabels() =
        fetchSemanticsNode()
            .config
            .getOrNull(SemanticsActions.CustomActions)
            .orEmpty()
            .map { it.label }

    private fun SemanticsNodeInteraction.invokeCustomAction(label: String) {
        val action = fetchSemanticsNode().config[SemanticsActions.CustomActions].first { it.label == label }
        rule.runOnUiThread { action.action() }
    }

    // region Lignes et TalkBack

    @Test
    fun theHeaderShowsWhatRemainsTheStoreAndWhatTheAppKnows() {
        show()
        // Affiché en ticket (« CARREFOUR », « RESTE 02 ») ; lu d'un bloc, dans l'ordre de #6 §5.
        val header = rule.onNodeWithTag(TAG_HEADER)
        header.assert(hasContentDescription("2 à prendre, Carrefour, Vous tracez le premier trajet ici"))
        assertTrue(header.fetchSemanticsNode().config.contains(SemanticsProperties.Heading))
        rule.onNodeWithText("02", useUnmergedTree = true).assertExists()
        rule.onNodeWithText("Semaine").assertExists()
    }

    @Test
    fun aRowReadsItsLabelAndQuantityAndItsStateWithoutColor() {
        show(base.copy(basket = listOf(milk)))
        rule.onNodeWithContentDescription("pommes, 2").assert(hasStateDescription("non coché"))
        rule.onNodeWithText("2").assertExists()
    }

    @Test
    fun theDefaultActionIsCheckAndTheCustomActionsAreNotFoundAndUncheck() {
        show(base.copy(toBuy = listOf(apples.copy(isChecked = true), bread), sections = emptyList()))
        val unchecked = rule.onNodeWithContentDescription("pain")
        val onClick = unchecked.fetchSemanticsNode().config[SemanticsActions.OnClick]
        assertEquals("Cocher", onClick.label)
        assertEquals(listOf("Pas trouvé"), unchecked.customActionLabels())

        val checked = rule.onNodeWithContentDescription("pommes, 2")
        checked.assert(hasStateDescription("coché"))
        assertEquals("Décocher", checked.fetchSemanticsNode().config[SemanticsActions.OnClick].label)
        assertEquals(listOf("Décocher"), checked.customActionLabels())
    }

    @Test
    fun tappingARowChecksIt() {
        show()
        rule.onNodeWithContentDescription("pain").performClick()
        assertEquals(listOf("2"), toggled)
    }

    @Test
    fun theTalkBackActionsReachTheModel() {
        show(base.copy(toBuy = listOf(apples.copy(isChecked = true), bread), sections = emptyList()))
        rule.onNodeWithContentDescription("pain").invokeCustomAction("Pas trouvé")
        rule.onNodeWithContentDescription("pommes, 2").invokeCustomAction("Décocher")
        assertEquals(listOf("2"), notFound)
        assertEquals(listOf("1"), toggled)
    }

    @Test
    fun everyRowIsAtLeast48DpHigh() {
        show()
        val density = rule.density
        listOf("pain", "pommes, 2").forEach {
            val height =
                rule
                    .onNodeWithContentDescription(it)
                    .fetchSemanticsNode()
                    .size.height
            assertTrue(height >= with(density) { 48.dp.roundToPx() })
        }
    }

    // endregion

    // region Rayons et ordre

    @Test
    fun outsideTheLearnedOrderAislesGetHeadingsWithTheirCount() {
        show()
        val heading = rule.onNodeWithContentDescription("Fruits et légumes, 1 à prendre")
        assertTrue(heading.fetchSemanticsNode().config.contains(SemanticsProperties.Heading))
        rule.onNodeWithContentDescription("Boulangerie, pâtisserie, 1 à prendre").assertExists()
    }

    @Test
    fun theLearnedThreadMarksEachAisleRunWithAHeading() {
        // Mode appris : un titre à chaque changement de rayon le long du trajet, même pour un rayon traversé deux fois.
        val oil = ShoppingRow("4", "huile", null, isChecked = false, aisleId = "produce")
        show(
            base.copy(
                toBuy = listOf(apples, bread, oil),
                sections =
                    listOf(
                        ShoppingSection("produce", "Fruits et légumes", listOf(apples)),
                        ShoppingSection("bakery", "Boulangerie, pâtisserie", listOf(bread)),
                        ShoppingSection("produce", "Fruits et légumes", listOf(oil), occurrence = 1),
                    ),
                groupsByAisle = false,
                knowledge = RouteKnowledge.Learned(80),
            ),
        )
        assertEquals(
            2,
            rule.onAllNodesWithContentDescription("Fruits et légumes, 1 à prendre").fetchSemanticsNodes().size,
        )
        rule.onNodeWithTag(TAG_HEADER).assert(hasContentDescription("Trajet connu à 80 %", substring = true))
        rule.onNodeWithContentDescription("pain").assertExists()
    }

    @Test
    fun noStoreSaysSo() {
        show(base.copy(storeName = null, knowledge = RouteKnowledge.NoStore))
        rule.onNodeWithTag(TAG_HEADER).assert(hasContentDescription("Sans magasin : ordre par rayon", substring = true))
    }

    @Test
    fun theBasketIsCollapsedUntilOpened() {
        show(base.copy(basket = listOf(milk)))
        rule.onNodeWithTag(TAG_BASKET).assert(hasStateDescription("replié"))
        rule.onNodeWithText("Dans le panier (1)").assertExists()
        rule.onNodeWithContentDescription("lait").assertDoesNotExist()
        rule.onNodeWithTag(TAG_BASKET).performClick()
        rule.onNodeWithTag(TAG_BASKET).assert(hasStateDescription("déplié"))
        rule.onNodeWithContentDescription("lait").assertExists()
    }

    @Test
    fun aNotFoundRowCanBePutBack() {
        show(base.copy(notFound = listOf(ShoppingRow("9", "huile", null, false, "savory-grocery"))))
        rule.onNodeWithText("Introuvable").assertExists()
        rule.onNodeWithContentDescription("huile").assert(hasStateDescription("introuvable"))
        rule.onNodeWithContentDescription("huile").performClick()
        assertEquals(listOf("9"), restored)
    }

    // endregion

    // region Annulation, annonce, erreur

    @Test
    fun theUndoBannerNamesTheActionAndUndoes() {
        show(base.copy(undo = ShoppingUndo(ShoppingUndo.Kind.Check, "2", "pain", "c1", 1)))
        rule.onNodeWithText("pain coché").assertExists()
        rule.onNodeWithTag(TAG_UNDO).performClick()
        assertEquals(1, undone)
    }

    @Test
    fun theNotFoundUndoSaysSo() {
        show(base.copy(undo = ShoppingUndo(ShoppingUndo.Kind.NotFound, "2", "pain", null, 1)))
        rule.onNodeWithText("pain introuvable").assertExists()
    }

    @Test
    fun aReorderIsAnnouncedOnceThroughTheAnnouncementApiWithoutANodeOfItsOwn() {
        show(base.copy(reorder = ReorderAnnouncement(seq = 3, next = "lait demi-écrémé")))
        rule.waitForIdle()
        assertEquals(listOf("Liste réordonnée. Prochain : lait demi-écrémé"), announced)
        // Aucun nœud dédié : rien que TalkBack puisse focaliser, et le titre n'est pas une région « live ».
        rule.onNodeWithContentDescription("Liste réordonnée. Prochain : lait demi-écrémé").assertDoesNotExist()
        val title = rule.onNodeWithTag(TAG_TITLE).fetchSemanticsNode().config
        assertTrue(!title.contains(SemanticsProperties.LiveRegion))
        rule.mainClock.advanceTimeBy(2_500)
        assertEquals(listOf(3), shown)
        assertEquals(1, announced.size)
    }

    @Test
    fun fromApi36TheTitleBecomesAPoliteLiveRegionDuringTheAnnouncement() {
        show(base.copy(reorder = ReorderAnnouncement(seq = 4, next = "pain")), announceWithApi = false)
        val title = rule.onNodeWithTag(TAG_TITLE).fetchSemanticsNode().config
        assertEquals(LiveRegionMode.Polite, title[SemanticsProperties.LiveRegion])
        assertEquals("Liste réordonnée. Prochain : pain", title[SemanticsProperties.StateDescription])
        // Le titre reste un texte ordinaire : ni action ni focus déplacé.
        assertTrue(!title.contains(SemanticsActions.OnClick))
    }

    @Test
    fun withoutReorderNothingIsAnnounced() {
        show()
        rule.waitForIdle()
        assertTrue(announced.isEmpty())
        val title = rule.onNodeWithTag(TAG_TITLE).fetchSemanticsNode().config
        assertTrue(!title.contains(SemanticsProperties.LiveRegion))
    }

    @Test
    fun anErrorIsShownInADialog() {
        show(base.copy(errorMessage = "Cette liste a été supprimée."))
        rule.onNodeWithText("Cette liste a été supprimée.").assertExists()
        rule.onNodeWithText("OK").performClick()
        assertEquals(1, dismissed)
    }

    // endregion

    // region Fin

    @Test
    fun finishingWithRemainingItemsAsksWhatToDoWithThem() {
        show(base.copy(notFound = listOf(ShoppingRow("9", "huile", null, false))))
        rule.onNodeWithTag(TAG_FINISH).performClick()
        rule.onNodeWithText("3 articles non cochés").assertExists()
        rule.onNodeWithText("Les garder pour la prochaine fois ?").assertExists()
        rule.onNodeWithTag(TAG_CONTINUE).performClick()
        rule.onNodeWithTag(TAG_REMAINING_SHEET).assertDoesNotExist()
        assertTrue(finished.isEmpty())
    }

    @Test
    fun keepingOrDroppingTheRemainingItemsFinishes() {
        show()
        rule.onNodeWithTag(TAG_FINISH).performClick()
        rule.onNodeWithTag(TAG_KEEP).performClick()
        assertEquals(listOf(true), finished)
    }

    @Test
    fun droppingTheRemainingItemsFinishesWithoutKeepingThem() {
        show()
        rule.onNodeWithTag(TAG_FINISH).performClick()
        rule.onNodeWithTag(TAG_DROP).performClick()
        assertEquals(listOf(false), finished)
    }

    @Test
    fun finishingWhenEverythingIsCheckedAsksNothing() {
        show(base.copy(toBuy = listOf(apples.copy(isChecked = true)), sections = emptyList()))
        rule.onNodeWithText("Tout est coché !").assertExists()
        rule.onNodeWithTag(TAG_FINISH).performClick()
        assertEquals(listOf(true), finished)
    }

    @Test
    fun anExpiredVisitForcesTheChoiceWithoutAWayBack() {
        show(base.copy(expired = true))
        rule.onNodeWithTag(TAG_REMAINING_SHEET).assertExists()
        rule.onNodeWithTag(TAG_CONTINUE).assertDoesNotExist()
        rule.onNodeWithText("Votre visite s'est terminée d'elle-même après 45 minutes sans coche.").assertExists()
    }

    @Test
    fun aSummaryInTheStateShowsTheEndScreen() {
        show(base.copy(summary = ShoppingSummary(12, 18, "Carrefour", RouteKnowledge.Learning(40), "v1")))
        rule.onNodeWithText("Carrefour est cartographié à 40\u202F%, merci.").assertExists()
        // Repli du mode courses : c'est l'entrée du résumé qui s'annonce à TalkBack, pas lui.
        rule.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.PaneTitle)).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ENTRY).assertDoesNotExist()
        rule.onNodeWithTag(TAG_CLOSE).performClick()
        assertEquals(1, closed)
    }

    // endregion

    // region Texte agrandi

    @Test
    fun at200PercentTheDockStacksAndEverythingStaysReachable() {
        show(fontScale = 2f)
        rule.onNodeWithTag(TAG_ENTRY).assertIsDisplayed()
        rule.onNodeWithTag(TAG_FINISH).assertIsDisplayed()
        rule.onNodeWithContentDescription("pain").assertIsDisplayed()
        val entry = rule.onNodeWithTag(TAG_ENTRY).fetchSemanticsNode().boundsInRoot
        val finish = rule.onNodeWithTag(TAG_FINISH).fetchSemanticsNode().boundsInRoot
        assertTrue("Terminer sous le champ", finish.top >= entry.bottom - 1)
    }

    @Test
    fun rowsGrowWithTheirTextAt200Percent() {
        show(
            base.copy(
                toBuy = listOf(apples.copy(label = "tomates cerises en grappe bio du maraîcher")),
                sections = emptyList(),
                groupsByAisle = false,
            ),
            fontScale = 2f,
        )
        val node = rule.onNodeWithContentDescription("tomates cerises en grappe bio du maraîcher, 2")
        node.assertIsDisplayed()
        assertTrue(node.fetchSemanticsNode().size.height > with(rule.density) { 48.dp.roundToPx() })
    }

    // endregion
}
