package fr.parcourses.app

import android.app.Application
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.Density
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import fr.parcourses.core.data.repository.ListSummary
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.feature.lists.ItemRow
import fr.parcourses.feature.lists.ItemSection
import fr.parcourses.feature.lists.ListDetailScreen
import fr.parcourses.feature.lists.ListDetailUiState
import fr.parcourses.feature.lists.ListsScreen
import fr.parcourses.feature.lists.ListsUiState
import fr.parcourses.feature.shopping.RouteKnowledge
import fr.parcourses.feature.shopping.ShoppingActions
import fr.parcourses.feature.shopping.ShoppingRow
import fr.parcourses.feature.shopping.ShoppingScreen
import fr.parcourses.feature.shopping.ShoppingSection
import fr.parcourses.feature.shopping.ShoppingSummary
import fr.parcourses.feature.shopping.ShoppingSummaryScreen
import fr.parcourses.feature.shopping.ShoppingUiState
import fr.parcourses.feature.shopping.ShoppingUndo
import fr.parcourses.feature.storepicker.StoreCandidate
import fr.parcourses.feature.storepicker.StorePickerActions
import fr.parcourses.feature.storepicker.StorePickerPhase
import fr.parcourses.feature.storepicker.StorePickerScreen
import fr.parcourses.feature.storepicker.StorePickerUiState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Captures de référence de la direction B3 (#6) : chaque écran en clair, en sombre et avec la police à 200 %.
 * `./gradlew :app:recordRoborazziDebug` les écrit dans `app/src/test/screenshots/`, `:app:verifyRoborazziDebug` les
 * compare. Lancés par `testDebugUnitTest` sans l'une de ces tâches, les tests composent chaque écran sans rien écrire :
 * une composition qui plante fait échouer la CI.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
// Application neutre : celle de l'app ouvre la base (SQLite natif), inutile pour composer un écran.
@Config(qualifiers = "w411dp-h891dp-xxhdpi", application = Application::class)
class ScreenshotTest {
    @get:Rule
    val rule = createComposeRule()

    private fun capture(
        name: String,
        dark: Boolean = false,
        fontScale: Float = 1f,
        content: @Composable () -> Unit,
    ) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                ParcoursesTheme(darkTheme = dark) { content() }
            }
        }
        rule.mainClock.advanceTimeBy(SETTLE_MS)
        rule.onRoot().captureRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
    }

    // region Données

    private val lists =
        ListsUiState(
            lists =
                listOf(
                    ListSummary("1", "Courses de la semaine", remaining = 7, total = 9),
                    ListSummary("2", "Apéro samedi", remaining = 0, total = 4),
                    ListSummary("3", "Bricolage", remaining = 0, total = 0),
                ),
            isLoaded = true,
        )

    private fun item(
        id: String,
        label: String,
        quantity: String?,
        category: String,
        checked: Boolean = false,
    ) = ItemRow(id, label, quantity, category, label.lowercase(), checked)

    private val detail =
        ListDetailUiState(
            name = "Courses de la semaine",
            sections =
                listOf(
                    ItemSection(
                        "produce",
                        "Fruits et légumes",
                        listOf(item("1", "Tomates", "6", "produce"), item("2", "Basilic", "1", "produce")),
                    ),
                    ItemSection("bio", "Bio", listOf(item("3", "Quinoa", "500 g", "bio"))),
                    ItemSection(
                        "dairy",
                        "Crèmerie, œufs, ultra-frais",
                        listOf(item("4", "Lait entier", "2", "dairy"), item("5", "Comté", "200 g", "dairy", true)),
                    ),
                    ItemSection("savory-grocery", "Épicerie salée", listOf(item("6", "Pâtes", null, "savory-grocery"))),
                ),
            isLoaded = true,
        )

    private fun row(
        id: String,
        label: String,
        quantity: String?,
        aisle: String,
        checked: Boolean = false,
    ) = ShoppingRow(id, label, quantity, checked, aisle)

    private val tomatoes = row("1", "Tomates", "6", "produce", checked = true)
    private val basil = row("2", "Basilic", "1", "produce")
    private val milk = row("3", "Lait entier", "2", "dairy")
    private val cheese = row("4", "Comté", "200 g", "dairy")
    private val pasta = row("5", "Pâtes", null, "savory-grocery")
    private val coffee = row("6", "Café moulu", "1", "savory-grocery")

    private val learned =
        ShoppingUiState(
            isLoaded = true,
            name = "Courses de la semaine",
            storeName = "Super U · Rennes Cleunay",
            toBuy = listOf(tomatoes, basil, pasta, coffee, milk, cheese),
            basket = listOf(row("7", "Pain", null, "bakery", checked = true)),
            sections =
                listOf(
                    ShoppingSection("produce", "Fruits et légumes", listOf(tomatoes, basil)),
                    ShoppingSection("savory-grocery", "Épicerie salée", listOf(pasta, coffee)),
                    ShoppingSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk, cheese)),
                ),
            groupsByAisle = false,
            knowledge = RouteKnowledge.Learned(82),
            undo = ShoppingUndo(ShoppingUndo.Kind.Check, "1", "Tomates", "c1", 0),
        )

    private val unknown =
        learned.copy(
            storeName = "Carrefour City · Colombier",
            toBuy = listOf(basil, milk, cheese, pasta),
            sections =
                listOf(
                    ShoppingSection("produce", "Fruits et légumes", listOf(basil)),
                    ShoppingSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk, cheese)),
                    ShoppingSection("savory-grocery", "Épicerie salée", listOf(pasta)),
                ),
            groupsByAisle = true,
            knowledge = RouteKnowledge.Unknown,
            basket = emptyList(),
            notFound = listOf(row("8", "Safran", null, "savory-grocery")),
            undo = null,
        )

    private val picker =
        StorePickerUiState(
            phase =
                StorePickerPhase.Precise(
                    proposed =
                        StoreCandidate(
                            "s1",
                            "Super U · Cleunay",
                            address = "Rue Jules Lallemand",
                            distanceM = 350.0,
                        ),
                    others =
                        listOf(
                            StoreCandidate(
                                "s2",
                                "Carrefour City · Colombier",
                                address = "Place Colombier",
                                distanceM = 900.0,
                            ),
                            StoreCandidate("s3", "Biocoop · Bréquigny", address = "Bd Albert 1er", distanceM = 1400.0),
                        ),
                ),
        )

    private val pickerActions = StorePickerActions({}, {}, {}, {}, {}, {}, {}, {}, {})

    private val summary = ShoppingSummary(12, 18, "Super U · Rennes Cleunay", RouteKnowledge.Learned(82))

    // endregion

    // region Listes

    @Test
    fun listsLight() = capture("lists-light") { ListsScreen(lists, {}, {}, { _, _ -> }, {}, {}) }

    @Test
    fun listsDark() = capture("lists-dark", dark = true) { ListsScreen(lists, {}, {}, { _, _ -> }, {}, {}) }

    @Test
    fun listsLarge() = capture("lists-200", fontScale = 2f) { ListsScreen(lists, {}, {}, { _, _ -> }, {}, {}) }

    @Composable
    private fun Detail() = ListDetailScreen(detail, TextFieldState(), {}, {}, {}, {}, {}, {}, onStartShopping = {})

    @Test
    fun detailLight() = capture("list-detail-light") { Detail() }

    @Test
    fun detailDark() = capture("list-detail-dark", dark = true) { Detail() }

    @Test
    fun detailLarge() = capture("list-detail-200", fontScale = 2f) { Detail() }

    // endregion

    // region Choix du magasin

    @Test
    fun pickerLight() = capture("store-picker-light") { StorePickerScreen(picker, TextFieldState(), pickerActions) }

    @Test
    fun pickerDark() =
        capture("store-picker-dark", dark = true) { StorePickerScreen(picker, TextFieldState(), pickerActions) }

    @Test
    fun pickerLarge() =
        capture("store-picker-200", fontScale = 2f) { StorePickerScreen(picker, TextFieldState(), pickerActions) }

    // endregion

    // region Mode courses

    @Test
    fun shoppingLearnedLight() =
        capture(
            "shopping-learned-light",
        ) { ShoppingScreen(learned, TextFieldState(), ShoppingActions(), announce = {}) }

    @Test
    fun shoppingLearnedDark() =
        capture("shopping-learned-dark", dark = true) {
            ShoppingScreen(learned, TextFieldState(), ShoppingActions(), announce = {})
        }

    @Test
    fun shoppingLearnedLarge() =
        capture("shopping-learned-200", fontScale = 2f) {
            ShoppingScreen(learned, TextFieldState(), ShoppingActions(), announce = {})
        }

    @Test
    fun shoppingUnknownLight() =
        capture(
            "shopping-unknown-light",
        ) { ShoppingScreen(unknown, TextFieldState(), ShoppingActions(), announce = {}) }

    @Test
    fun shoppingUnknownDark() =
        capture("shopping-unknown-dark", dark = true) {
            ShoppingScreen(unknown, TextFieldState(), ShoppingActions(), announce = {})
        }

    @Test
    fun summaryLight() = capture("summary-light") { ShoppingSummaryScreen(summary, {}) }

    @Test
    fun summaryDark() = capture("summary-dark", dark = true) { ShoppingSummaryScreen(summary, {}) }

    @Test
    fun summaryLarge() = capture("summary-200", fontScale = 2f) { ShoppingSummaryScreen(summary, {}) }

    // endregion

    // region À propos

    @Test
    fun aboutLight() = capture("about-light") { AboutScreen("0.1.0 (1)", {}) }

    @Test
    fun aboutDark() = capture("about-dark", dark = true) { AboutScreen("0.1.0 (1)", {}) }

    @Test
    fun aboutLarge() = capture("about-200", fontScale = 2f) { AboutScreen("0.1.0 (1)", {}) }

    // Clé de session illisible (#51) : la section « Session » passe en tête.
    private val stuckSession = SessionResetUiState(visible = true)

    @Test
    fun aboutSessionLight() =
        capture("about-session-light") { AboutScreen("0.1.0 (1)", {}, sessionReset = stuckSession) }

    @Test
    fun aboutSessionDark() =
        capture("about-session-dark", dark = true) { AboutScreen("0.1.0 (1)", {}, sessionReset = stuckSession) }

    // endregion

    /** L'anticrénelage peut varier d'une machine à l'autre (macOS en local, Linux en CI) : 1 % de pixels tolérés. */
    private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

    private companion object {
        /** Laisse finir les animations d'apparition (barre « Annuler », fil). */
        const val SETTLE_MS = 1_000L
    }
}
