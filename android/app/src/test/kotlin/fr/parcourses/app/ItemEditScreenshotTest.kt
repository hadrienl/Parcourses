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
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import fr.parcourses.core.designsystem.ItemEditTarget
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.feature.lists.ItemRow
import fr.parcourses.feature.lists.ItemSection
import fr.parcourses.feature.lists.ListDetailScreen
import fr.parcourses.feature.lists.ListDetailUiState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Captures de référence de la quantité d'un article (#110) : l'astuce au-dessus des articles, le panneau de l'article
 * (feuille modale, capturée avec sa fenêtre), et les lignes à libellé ou quantité longs, en clair, en sombre et avec la
 * police à 200 %. Même
 * fonctionnement que [ScreenshotTest].
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w411dp-h891dp-xxhdpi", application = Application::class)
@OptIn(ExperimentalRoborazziApi::class)
class ItemEditScreenshotTest {
    @get:Rule
    val rule = createComposeRule()

    private fun compose(
        dark: Boolean,
        fontScale: Float,
        content: @Composable () -> Unit,
    ) {
        rule.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                ParcoursesTheme(darkTheme = dark) { content() }
            }
        }
        rule.mainClock.advanceTimeBy(SETTLE_MS)
    }

    private fun capture(
        name: String,
        dark: Boolean = false,
        fontScale: Float = 1f,
        content: @Composable () -> Unit,
    ) {
        compose(dark, fontScale, content)
        rule.onRoot().captureRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
    }

    /** La feuille vit dans sa propre fenêtre : tout l'écran est capturé, liste comprise sous le voile. */
    private fun captureScreen(
        name: String,
        dark: Boolean = false,
        fontScale: Float = 1f,
        content: @Composable () -> Unit,
    ) {
        compose(dark, fontScale, content)
        rule.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
    }

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
                    ItemSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(item("3", "Lait entier", "2", "dairy"))),
                    ItemSection(
                        "savory-grocery",
                        "Épicerie salée",
                        listOf(item("4", "Farine de blé T65", "500 g", "savory-grocery")),
                    ),
                ),
            isLoaded = true,
        )

    /**
     * Libellé long, quantité longue, et les deux (#110) : seul le libellé se replie, la quantité reste à droite sur
     * sa première ligne ; une quantité qui prendrait trop de place passe dessous.
     */
    private val longLines =
        ListDetailUiState(
            name = "Courses de la semaine",
            sections =
                listOf(
                    ItemSection(
                        "dairy",
                        "Crèmerie, œufs, ultra-frais",
                        listOf(
                            item("1", "Lait demi-écrémé bio de montagne en bouteille de verre", "2", "dairy"),
                            item("2", "Yaourts", "6x33cl", "dairy"),
                            item("3", "Fromage blanc fermier au lait cru de vache", "1,5 kg", "dairy"),
                            item("4", "Beurre", "2 plaquettes de 250 g doux", "dairy"),
                        ),
                    ),
                ),
            isLoaded = true,
        )

    private val withTip = detail.copy(showsQuantityTip = true)
    private val editing = detail.copy(editing = ItemEditTarget("4", "Farine de blé T65", "500 g"))

    @Composable
    private fun Detail(state: ListDetailUiState) =
        ListDetailScreen(state, TextFieldState(), {}, {}, {}, {}, {}, {}, onStartShopping = {})

    @Test
    fun tipLight() = capture("list-detail-tip-light") { Detail(withTip) }

    @Test
    fun tipDark() = capture("list-detail-tip-dark", dark = true) { Detail(withTip) }

    @Test
    fun tipLarge() = capture("list-detail-tip-200", fontScale = 2f) { Detail(withTip) }

    @Test
    fun longLinesLight() = capture("item-lines-light") { Detail(longLines) }

    @Test
    fun longLinesLarge() = capture("item-lines-200", fontScale = 2f) { Detail(longLines) }

    @Test
    fun sheetLight() = captureScreen("item-edit-light") { Detail(editing) }

    @Test
    fun sheetDark() = captureScreen("item-edit-dark", dark = true) { Detail(editing) }

    @Test
    fun sheetLarge() = captureScreen("item-edit-200", fontScale = 2f) { Detail(editing) }

    /** L'anticrénelage peut varier d'une machine à l'autre (macOS en local, Linux en CI) : 1 % de pixels tolérés. */
    private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

    private companion object {
        const val SETTLE_MS = 1_000L
    }
}
