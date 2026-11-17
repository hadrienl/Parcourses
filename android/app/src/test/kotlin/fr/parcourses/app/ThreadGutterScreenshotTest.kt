package fr.parcourses.app

import android.app.Application
import android.graphics.Bitmap
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.Composable
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureRoboImage
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.feature.lists.ItemRow
import fr.parcourses.feature.lists.ItemSection
import fr.parcourses.feature.lists.ListDetailScreen
import fr.parcourses.feature.lists.ListDetailUiState
import fr.parcourses.feature.shopping.RouteKnowledge
import fr.parcourses.feature.shopping.ShoppingActions
import fr.parcourses.feature.shopping.ShoppingRow
import fr.parcourses.feature.shopping.ShoppingScreen
import fr.parcourses.feature.shopping.ShoppingSection
import fr.parcourses.feature.shopping.ShoppingUiState
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.roundToInt

/**
 * Gouttière invariante (#115, §6.4) : pendant qu'une ligne s'enfonce ou que son couloir glisse, les pixels de la
 * gouttière (perles, nœuds) et du trait restent identiques à ceux du repos. Seul le couloir bouge. La colonne de la
 * gouttière de chaque état est aussi capturée par Roborazzi (`recordRoborazziDebug`, `verifyRoborazziDebug`).
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w411dp-h891dp-xxhdpi", application = Application::class)
class ThreadGutterScreenshotTest {
    @get:Rule
    val rule = createComposeRule()

    private val basil = ShoppingRow("2", "Basilic", "1", false, "produce")
    private val milk = ShoppingRow("3", "Lait entier", "2", false, "dairy")
    private val pasta = ShoppingRow("5", "Pâtes", null, false, "savory-grocery")
    private val shopping =
        ShoppingUiState(
            isLoaded = true,
            name = "Courses de la semaine",
            storeName = "Super U · Rennes Cleunay",
            toBuy = listOf(basil, milk, pasta),
            sections =
                listOf(
                    ShoppingSection("produce", "Fruits et légumes", listOf(basil)),
                    ShoppingSection("dairy", "Crèmerie, œufs, ultra-frais", listOf(milk)),
                    ShoppingSection("savory-grocery", "Épicerie salée", listOf(pasta)),
                ),
            groupsByAisle = false,
            knowledge = RouteKnowledge.Learned(82),
        )

    private val detail =
        ListDetailUiState(
            name = "Courses de la semaine",
            sections =
                listOf(
                    ItemSection(
                        "produce",
                        "Fruits et légumes",
                        listOf(ItemRow("1", "Tomates", "6", "produce", "tomates", false)),
                    ),
                    ItemSection(
                        "dairy",
                        "Crèmerie, œufs, ultra-frais",
                        listOf(ItemRow("4", "Lait", "2", "dairy", "lait", false)),
                    ),
                ),
            isLoaded = true,
        )

    @Test
    fun theShoppingGutterStaysPutWhileTheLaneSinksAndSlides() {
        show { ShoppingScreen(shopping, TextFieldState(), ShoppingActions(), announce = {}) }
        val rest = snapshot("thread-gutter-shopping-rest", SHOPPING_LIST)
        val row = rule.onNodeWithContentDescription("Lait entier, 2")
        rule.mainClock.autoAdvance = false
        row.performTouchInput { down(Offset(width * 0.6f, centerY)) }
        rule.mainClock.advanceTimeBy(PRESS_MS)
        val pressed = snapshot("thread-gutter-shopping-pressed", SHOPPING_LIST)
        row.performTouchInput { moveBy(Offset(SWIPE_DP * density, 0f)) }
        rule.mainClock.advanceTimeBy(PRESS_MS)
        val swiped = snapshot("thread-gutter-shopping-swiped", SHOPPING_LIST)
        row.performTouchInput { up() }
        rule.mainClock.autoAdvance = true

        assertArrayEquals("enfoncée : gouttière et trait inchangés", rest.gutter, pressed.gutter)
        assertArrayEquals("glissée : gouttière et trait inchangés", rest.gutter, swiped.gutter)
        assertFalse("le couloir a bien glissé", rest.lane.contentEquals(swiped.lane))
    }

    @Test
    fun theListGutterStaysPutWhileTheLaneSinks() {
        show { ListDetailScreen(detail, TextFieldState(), {}, {}, {}, {}, {}, {}, onStartShopping = {}) }
        val rest = snapshot("thread-gutter-detail-rest", DETAIL_LIST)
        val row = rule.onNodeWithContentDescription("Lait, 2")
        // Case et libellé de la ligne « Lait » (`TAG_ITEM_CONTENT`), mis à l'échelle pendant l'appui.
        val content = rule.onAllNodesWithTag(ITEM_CONTENT, useUnmergedTree = true)[1]
        val contentAtRest = content.fetchSemanticsNode().boundsInRoot
        rule.mainClock.autoAdvance = false
        row.performTouchInput { down(Offset(width * 0.6f, centerY)) }
        rule.mainClock.advanceTimeBy(PRESS_MS)
        val pressed = snapshot("thread-gutter-detail-pressed", DETAIL_LIST)
        val contentPressed = content.fetchSemanticsNode().boundsInRoot
        row.performTouchInput { up() }
        rule.mainClock.autoAdvance = true

        assertArrayEquals("enfoncée : gouttière et trait inchangés", rest.gutter, pressed.gutter)
        assertTrue("le couloir s'est bien enfoncé", contentPressed.width < contentAtRest.width)
    }

    // region Outils

    private fun show(content: @Composable () -> Unit) {
        rule.setContent { ParcoursesTheme(darkTheme = false) { content() } }
        rule.mainClock.advanceTimeBy(SETTLE_MS)
    }

    /** Pixels de la colonne gouttière + trait et du reste de la liste (le couloir), et capture Roborazzi. */
    private class Pixels(
        val gutter: IntArray,
        val lane: IntArray,
    )

    /**
     * Pixels de la colonne gouttière + trait et du reste de la liste (le couloir). La capture Roborazzi ne garde que la
     * colonne de la gouttière : l'ondulation du couloir (`RippleDrawable`) avance en temps réel et changerait d'un
     * lancement à l'autre.
     */
    private fun snapshot(
        name: String,
        listTag: String,
    ): Pixels {
        val image = rule.onRoot().captureToImage()
        val list = rule.onNodeWithTag(listTag).fetchSemanticsNode().boundsInRoot
        val density = rule.density.density
        val split = list.left + (ThreadLayout.start + TicketDimens.threadGutter).value * density
        val gutter = Rect(list.left, list.top, split, list.bottom)
        image.crop(gutter).captureRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
        return Pixels(
            gutter = image.pixels(gutter),
            lane = image.pixels(Rect(split, list.top, list.right, list.bottom)),
        )
    }

    private fun ImageBitmap.crop(area: Rect): Bitmap {
        val left = area.left.roundToInt()
        val top = area.top.roundToInt()
        val width = area.width.roundToInt().coerceAtMost(this.width - left)
        val height = area.height.roundToInt().coerceAtMost(this.height - top)
        return Bitmap.createBitmap(asAndroidBitmap(), left, top, width, height)
    }

    private fun ImageBitmap.pixels(area: Rect): IntArray =
        crop(
            area,
        ).let { IntArray(it.width * it.height).apply { it.getPixels(this, 0, it.width, 0, 0, it.width, it.height) } }

    private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

    private companion object {
        const val SETTLE_MS = 1_000L
        const val PRESS_MS = 300L
        const val SWIPE_DP = 120f
        const val SHOPPING_LIST = "shoppingItems"
        const val DETAIL_LIST = "items"
        const val ITEM_CONTENT = "itemContent"
    }

    // endregion
}
