package fr.parcourses.feature.storepicker

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(qualifiers = "w400dp-h1800dp-xxhdpi")
class StorePickerScreenTest {
    @get:Rule
    val rule = createComposeRule()

    private val selected = mutableListOf<StoreCandidate>()
    private val events = mutableListOf<String>()
    private var queryState: TextFieldState? = null

    private val actions =
        StorePickerActions(
            onBack = { events += "back" },
            onSelect = { selected += it },
            onRequestPermission = { events += "permission" },
            onOpenSettings = { events += "settings" },
            onRetry = { events += "retry" },
            onContinueWithoutStore = { events += "without" },
            onDismissSelectionFailure = { events += "dismiss" },
        )

    private fun show(
        state: StorePickerUiState,
        fontScale: Float = 1f,
    ) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                ParcoursesTheme {
                    val query = rememberTextFieldState()
                    queryState = query
                    StorePickerScreen(state = state, query = query, actions = actions)
                }
            }
        }
    }

    private val here = StoreCandidate("1", "Carrefour Market", address = "12 rue Neuve", distanceM = 42.0)
    private val other = StoreCandidate("2", "Biocoop", address = "3 place Verte", distanceM = 1_234.0)
    private val recent = StoreCandidate("3", "Lidl", address = "8 quai Sud")

    @Test
    fun loadingExplainsWhatIsHappening() {
        show(StorePickerUiState())
        rule.onNodeWithText("Recherche des magasins proches…").assertIsDisplayed()
    }

    @Test
    fun aProposedStoreCanBeConfirmedInOneTap() {
        show(StorePickerUiState(phase = StorePickerPhase.Precise(here, listOf(other)), recents = listOf(recent)))
        rule.onNodeWithText("Vous êtes ici ?").assertIsDisplayed()
        rule.onNodeWithText("40 m").assertIsDisplayed()
        rule.onNodeWithText("1,2 km").assertIsDisplayed()
        rule.onNodeWithTag(TAG_CONFIRM_PROPOSAL).performClick()
        assertEquals(listOf(here), selected)
        rule.onNodeWithText("Autres magasins proches").assertIsDisplayed()
        rule.onNodeWithText("Récents").assertIsDisplayed()
    }

    @Test
    fun withoutProposalTheNearbyStoresAreJustListed() {
        show(StorePickerUiState(phase = StorePickerPhase.Precise(null, listOf(other))))
        rule.onNodeWithText("Vous êtes ici ?").assertDoesNotExist()
        rule.onNodeWithText("Magasins proches").assertIsDisplayed()
    }

    @Test
    fun aStoreAppearingInTwoSectionsDoesNotCrashTheList() {
        show(StorePickerUiState(phase = StorePickerPhase.Precise(null, listOf(other)), recents = listOf(other)))
        rule.onNodeWithText("Récents").assertIsDisplayed()
    }

    @Test
    fun aStoreRowIsOneButtonReadAsABlock() {
        show(StorePickerUiState(phase = StorePickerPhase.Precise(null, listOf(other))))
        // Nom, adresse et distance partagent un seul nœud actionnable : un seul arrêt pour TalkBack.
        val row = rule.onNode(hasClickAction() and hasText("Biocoop", substring = true))
        row.assertHasClickAction()
        row.assert(hasText("3 place Verte", substring = true))
        row.assert(hasText("1,2 km", substring = true))
        row.performClick()
        assertEquals(listOf(other), selected)
    }

    @Test
    fun sectionAndStatusTitlesAreHeadings() {
        show(StorePickerUiState(phase = StorePickerPhase.Offline, recents = listOf(recent)))
        val heading = SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading)
        rule.onNodeWithText("Récents").assert(heading)
        rule.onNodeWithText("Hors ligne", useUnmergedTree = true).assert(heading)
    }

    @Test
    fun approximatePositionShowsNoDistanceAndOffersPrecision() {
        show(StorePickerUiState(phase = StorePickerPhase.Approximate(listOf(other.copy(distanceM = null)))))
        rule.onNodeWithText("Magasins dans le secteur").assertIsDisplayed()
        rule.onNodeWithText("Biocoop", substring = true).assertIsDisplayed()
        rule.onNodeWithText("1,2 km").assertDoesNotExist()
        rule.onNodeWithTag(TAG_PRECISION).performClick()
        assertEquals(listOf("permission"), events)
    }

    @Test
    fun aDeclinedPrecisionIsSaid() {
        show(StorePickerUiState(phase = StorePickerPhase.Approximate(emptyList()), precisionDeclined = true))
        rule.onNodeWithText("Position précise non accordée : choisissez dans la liste.").assertIsDisplayed()
    }

    @Test
    fun theLocationRequestIsExplainedBeforeTheSystemDialog() {
        show(StorePickerUiState(phase = StorePickerPhase.PermissionNeeded))
        rule.onNodeWithText("Trouver votre magasin").assertIsDisplayed()
        rule.onNodeWithText("Elle n'est pas conservée.", substring = true).assertIsDisplayed()
        // Rien n'est demandé tant que l'utilisateur n'a pas appuyé.
        assertTrue(events.isEmpty())
        rule.onNodeWithTag(TAG_PRIMARY_ACTION).performClick()
        assertEquals(listOf("permission"), events)
        rule.onNodeWithTag(TAG_SEARCH).assertIsDisplayed()
        rule.onNodeWithTag(TAG_WITHOUT_STORE).assertIsDisplayed()
    }

    @Test
    fun aSimpleRefusalOffersToAllowAgain() {
        show(StorePickerUiState(phase = StorePickerPhase.Denied(canAskAgain = true)))
        rule.onNodeWithText("Autoriser la position").performClick()
        rule.onNodeWithText("Ouvrir les réglages").assertDoesNotExist()
        assertEquals(listOf("permission"), events)
    }

    @Test
    fun doNotAskAgainSendsToTheSettingsAndKeepsSearch() {
        show(StorePickerUiState(phase = StorePickerPhase.Denied(canAskAgain = false)))
        rule.onNodeWithText("autorisez-la dans les réglages de l'application", substring = true).assertIsDisplayed()
        rule.onNodeWithText("Autoriser la position").assertDoesNotExist()
        rule.onNodeWithText("Ouvrir les réglages").performClick()
        assertEquals(listOf("settings"), events)
        rule.onNodeWithTag(TAG_SEARCH).assertIsDisplayed()
    }

    @Test
    fun offlineKeepsTheRecentsAndAWayOut() {
        show(StorePickerUiState(phase = StorePickerPhase.Offline, recents = listOf(recent)))
        rule.onNodeWithText("Hors ligne").assertIsDisplayed()
        rule.onNodeWithTag(TAG_SEARCH).assertDoesNotExist()
        rule.onNodeWithText("Lidl", substring = true).performClick()
        assertEquals(listOf(recent), selected)
        rule.onNodeWithTag(TAG_PRIMARY_ACTION).performClick()
        rule.onNodeWithTag(TAG_WITHOUT_STORE).performClick()
        assertEquals(listOf("retry", "without"), events)
    }

    @Test
    fun serviceErrorAndEmptyStatesTalkPlainly() {
        show(StorePickerUiState(phase = StorePickerPhase.ServiceError))
        rule.onNodeWithText("Service indisponible").assertIsDisplayed()
    }

    @Test
    fun noStoreInTheAreaOffersSearchButNoRetry() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore))
        rule.onNodeWithText("Aucun magasin connu ici").assertIsDisplayed()
        rule.onNodeWithTag(TAG_PRIMARY_ACTION).assertDoesNotExist()
        rule.onNodeWithTag(TAG_SEARCH).assertIsDisplayed()
    }

    @Test
    fun theSearchFieldTakesTypedText() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore))
        rule.onNodeWithTag(TAG_SEARCH).performTextInput("carrefour")
        assertEquals("carrefour", queryState?.text.toString())
    }

    @Test
    fun searchResultsAndMessagesAreShown() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore, search = StoreSearchState.Results(listOf(other))))
        rule.onNodeWithText("Résultats de la recherche").assertIsDisplayed()
        rule.onNodeWithText("Biocoop", substring = true).performClick()
        assertEquals(listOf(other), selected)
    }

    @Test
    fun noResultAndFailureAreSaid() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore, search = StoreSearchState.Results(emptyList())))
        rule.onNodeWithText("Aucun magasin trouvé.").assertIsDisplayed()
    }

    @Test
    fun searchOfflineIsSaid() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore, search = StoreSearchState.Offline))
        rule.onNodeWithText("Recherche impossible hors ligne.").assertIsDisplayed()
    }

    @Test
    fun searchInProgressIsSaid() {
        show(StorePickerUiState(phase = StorePickerPhase.NoStore, search = StoreSearchState.Searching))
        rule.onNodeWithText("Recherche en cours…").assertIsDisplayed()
    }

    @Test
    fun theOpenStreetMapAttributionIsAlwaysVisible() {
        show(StorePickerUiState(phase = StorePickerPhase.Loading))
        rule.onNodeWithTag(TAG_ATTRIBUTION).assertIsDisplayed()
        rule.onNodeWithText("© contributeurs OpenStreetMap, licence ODbL").assertIsDisplayed()
    }

    @Test
    fun aFailedSaveIsExplainedAndDismissable() {
        show(StorePickerUiState(phase = StorePickerPhase.Offline, selectionFailed = true))
        rule.onNodeWithText("Impossible d'enregistrer ce magasin").assertIsDisplayed()
        rule.onNodeWithText("OK").performClick()
        assertEquals(listOf("dismiss"), events)
    }

    @Test
    fun theBackButtonLeaves() {
        show(StorePickerUiState())
        rule.onNodeWithContentDescription("Retour").performClick()
        assertEquals(listOf("back"), events)
    }

    @Test
    fun twiceTheTextSizeStillShowsEveryAction() {
        show(
            StorePickerUiState(
                phase = StorePickerPhase.Precise(here, listOf(other)),
                recents = listOf(recent),
            ),
            fontScale = 2f,
        )
        rule.onNodeWithTag(TAG_CONFIRM_PROPOSAL).assertIsDisplayed()
        rule.onNodeWithText("© contributeurs OpenStreetMap, licence ODbL").assertIsDisplayed()
    }
}
