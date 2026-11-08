package fr.parcourses.feature.shopping

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.hapticfeedback.HapticFeedback
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
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

/** Écran de fin (A9) : textes, contribution, TalkBack, texte à 200 % et vibration de réussite. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "w411dp-h891dp-xxhdpi")
class ShoppingSummaryScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private var closed = 0

    private fun show(
        summary: ShoppingSummary,
        fontScale: Float = 1f,
    ) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                ParcoursesTheme { ShoppingSummaryScreen(summary, onClose = { closed++ }) }
            }
        }
    }

    // region Textes et contribution

    @Test
    fun theSummaryReadsTheCountTheDurationAndThanksTheContribution() {
        show(ShoppingSummary(12, 18, "Carrefour", RouteKnowledge.Learning(40), "v1"))
        rule.onNodeWithText("12 articles", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("en 18 min", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithTag(TAG_CONTRIBUTION).assert(hasText("Carrefour est cartographié à 40 %, merci."))
        rule.onNodeWithTag(TAG_CLOSE).assert(hasText("Retour aux listes")).performClick()
        assertEquals(1, closed)
    }

    @Test
    fun aLearnedStoreIsThankedWithItsPercentage() {
        show(ShoppingSummary(3, 7, "Leclerc Auch", RouteKnowledge.Learned(82), "v1"))
        rule.onNodeWithText("Leclerc Auch est cartographié à 82 %, merci.").assertIsDisplayed()
    }

    @Test
    fun theFirstRouteIsThankedAndTheSingularIsWorded() {
        show(ShoppingSummary(1, 1, "Carrefour", RouteKnowledge.Unknown, "v1"))
        rule.onNodeWithText("1 article", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("en 1 min", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText("Vous avez tracé le premier trajet à Carrefour, merci.").assertIsDisplayed()
    }

    @Test
    fun withoutAStoreThereIsNoContribution() {
        show(ShoppingSummary(4, 9, null, RouteKnowledge.NoStore))
        rule.onNodeWithText("4 articles", useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithTag(TAG_CONTRIBUTION).assertDoesNotExist()
    }

    @Test
    fun aVisitWithoutAnyCheckContributesNothing() {
        // `closeVisit` a supprimé la visite faute de coche : rien n'est parti au serveur, rien à remercier.
        show(ShoppingSummary(0, 2, "Carrefour", RouteKnowledge.Unknown, visitId = null))
        rule.onNodeWithTag(TAG_SUMMARY, useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithTag(TAG_CONTRIBUTION).assertDoesNotExist()
    }

    // endregion

    // region TalkBack

    @Test
    fun theCountAndTheDurationAreOneHeadingAndThePaneIsNamed() {
        show(ShoppingSummary(12, 18, "Carrefour", RouteKnowledge.Learning(40), "v1"))
        val headline = rule.onNodeWithTag(TAG_SUMMARY_HEADLINE)
        headline.assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        val texts =
            headline
                .fetchSemanticsNode()
                .config[SemanticsProperties.Text]
                .map { it.text }
        assertEquals(listOf("12 articles", "en 18 min"), texts)
        rule
            .onNode(SemanticsMatcher.expectValue(SemanticsProperties.PaneTitle, "Courses terminées"))
            .assertExists()
    }

    @Test
    fun theCloseButtonIsALargeEnoughTarget() {
        show(ShoppingSummary(2, 5, "Carrefour", RouteKnowledge.Unknown, "v1"))
        val height =
            rule
                .onNodeWithTag(TAG_CLOSE)
                .fetchSemanticsNode()
                .size.height
        assertTrue(height >= with(rule.density) { 48.dp.roundToPx() })
    }

    // endregion

    // region Texte agrandi

    @Test
    @Config(qualifiers = "w320dp-h480dp-xxhdpi")
    fun at200PercentOnASmallScreenEverythingStaysReachable() {
        show(
            ShoppingSummary(
                12,
                18,
                "Intermarché Hyper de la Zone Commerciale des Trois Moulins",
                RouteKnowledge.Learning(40),
                "v1",
            ),
            fontScale = 2f,
        )
        // Le bouton reste visible, en bas ; le texte défile au-dessus de lui sans être coupé.
        val close = rule.onNodeWithTag(TAG_CLOSE)
        close.assertIsDisplayed()
        val root = rule.onRoot().fetchSemanticsNode().boundsInRoot
        assertTrue(close.fetchSemanticsNode().boundsInRoot.bottom <= root.bottom + 1)
        rule.onNodeWithTag(TAG_CONTRIBUTION).performScrollTo().assertIsDisplayed()
        val contribution = rule.onNodeWithTag(TAG_CONTRIBUTION).fetchSemanticsNode().boundsInRoot
        assertTrue("au-dessus du bouton", contribution.bottom <= close.fetchSemanticsNode().boundsInRoot.top + 1)
        close.performClick()
        assertEquals(1, closed)
    }

    // endregion

    // region Vibration

    @Test
    fun theSuccessHapticPlaysOnceEvenAfterARecreation() {
        val played = mutableListOf<HapticFeedbackType>()
        val haptics =
            object : HapticFeedback {
                override fun performHapticFeedback(hapticFeedbackType: HapticFeedbackType) {
                    played += hapticFeedbackType
                }
            }
        val restoration = StateRestorationTester(rule)
        restoration.setContent {
            CompositionLocalProvider(LocalHapticFeedback provides haptics) {
                ParcoursesTheme {
                    ShoppingSummaryRoute(ShoppingSummary(1, 1, null, RouteKnowledge.NoStore), onClose = {})
                }
            }
        }
        rule.waitForIdle()
        assertEquals(listOf(HapticFeedbackType.Confirm), played)

        // Rotation ou retour après la mort du processus : l'écran revient, la vibration ne repart pas.
        restoration.emulateSavedInstanceStateRestore()
        rule.waitForIdle()
        assertEquals(listOf(HapticFeedbackType.Confirm), played)
    }

    // endregion
}
