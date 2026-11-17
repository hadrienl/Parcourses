package fr.parcourses.feature.shopping

import android.os.Looper
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.AccessibilityPreferences
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.LocalThreadTrack
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.designsystem.RowLane
import fr.parcourses.core.designsystem.ThreadBead
import fr.parcourses.core.designsystem.ThreadGutter
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.ThreadPath
import fr.parcourses.core.designsystem.ThreadStyle
import fr.parcourses.core.designsystem.ThreadTrackState
import fr.parcourses.core.designsystem.TicketMotion
import fr.parcourses.core.designsystem.rememberThreadTrackState
import fr.parcourses.core.designsystem.threadTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowChoreographer
import org.robolectric.shadows.ShadowTrace
import org.robolectric.shadows.ShadowView
import java.time.Duration
import kotlin.math.abs
import kotlin.math.ceil

/**
 * Non-régression du trait unique (#115, banc du lot 0) : le trait que la liste a réellement dessiné, image par image,
 * contre la position réelle des perles première, suivante et dernière, pendant un tri, des départs et un défilement
 * rapide. Vrais parcours de dessin de Robolectric (rendu matériel, listes d'affichage) et Choreographer en pause : une
 * image = la trame Compose (animations), puis une vsync (mise en page, rappels de position, dessin), comme sur un
 * appareil. Tolérance : 1 dp ; aucun trou entre le trait et une perle de bout, même pendant un fondu.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w360dp-h1240dp-xhdpi")
class ThreadTrackRegressionTest {
    private val compose = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RealDrawTraversals()).around(compose)

    private val rows = mutableStateOf((0 until 20).map { "r$it" })
    private var next = 3
    private val coords = HashMap<String, LayoutCoordinates>()
    private lateinit var track: ThreadTrackState
    private lateinit var listState: LazyListState
    private lateinit var scope: CoroutineScope
    private var list: LayoutCoordinates? = null
    private val failures = ArrayList<String>()
    private var samples = 0
    private var worst = 0f

    @Test
    fun theTrackFollowsItsBeadsFrameByFrame() {
        compose.mainClock.autoAdvance = false
        quietTrace()
        compose.setContent { Ticket() }
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(FRAME_MS))
        repeat(20) { frame("repos", exact = true) }

        // Tri : la dernière ligne vient de l'index 10, la suivante (index 3) devient r7.
        change("tri") { rows.value = SORT.map { "r$it" } }
        // Départ de la première et de la dernière ligne : les autres remontent, les bouts restent tenus le temps du
        // fondu.
        change("départs") { rows.value = rows.value.drop(1).dropLast(1) }
        // Défilement rapide sur plusieurs écrans, aller et retour.
        rows.value = (0 until 100).map { "c$it" }
        next = 10
        Snapshot.sendApplyNotifications()
        repeat(30) { frame("installation", exact = false) }
        val step = 96f * compose.density.density
        scope.launch {
            repeat(SCROLL_FRAMES) {
                withFrameNanos { }
                listState.scrollBy(step)
            }
            repeat(SCROLL_FRAMES) {
                withFrameNanos { }
                listState.scrollBy(-step)
            }
        }
        repeat(2 * SCROLL_FRAMES + 4) { frame("défilement", exact = true) }

        println("ThreadTrackRegressionTest : $samples marqueurs vérifiés, écart max $worst dp hors fondus")
        assertTrue(failures.take(12).joinToString("\n"), failures.isEmpty())
        // Garde-fou : un trait jamais dessiné ne doit pas passer pour un trait exact.
        assertTrue("trop peu de marqueurs vérifiés : $samples", samples >= MIN_SAMPLES)
    }

    /** Un changement de la liste, puis les images qui suivent : écarts tolérés seulement le temps des fondus. */
    private fun change(
        name: String,
        action: () -> Unit,
    ) {
        action()
        Snapshot.sendApplyNotifications()
        // Bouts tenus (fondu) et jonction qui coule (coche) : on ne vérifie que l'absence de trou pendant ce temps.
        val settling = ceil(maxOf(TicketMotion.FADE_MS, TicketMotion.CHECK_MS).toFloat() / FRAME_MS).toInt() + 2
        repeat(SETTLE_FRAMES) { frame(name, exact = it >= settling) }
    }

    // region Pilotage image par image

    private fun frame(
        name: String,
        exact: Boolean,
    ) {
        quietTrace()
        compose.mainClock.advanceTimeByFrame()
        // 17 ms : la vsync demandée tombe dans l'intervalle, celle que le dessin redemande ensuite non.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(FRAME_MS + 1))
        check(name, exact)
    }

    private fun check(
        name: String,
        exact: Boolean,
    ) {
        val drawn = track.lastDrawn
        if (drawn == null) {
            failures += "$name : aucun trait dessiné"
            return
        }
        val keys = rows.value
        // Bout haut : pas de trou au-dessus de la première perle (le trait peut la dépasser le temps d'un fondu).
        measure(name, "bout haut", keys.firstOrNull(), drawn.top, exact) { shown, bead -> shown - bead }
        // Bout bas : pas de trou sous la dernière perle.
        measure(name, "bout bas", keys.lastOrNull(), drawn.bottom, exact) { shown, bead -> bead - shown }
        // Jonction : sur la perle suivante une fois la coulée finie ; aucun trou possible.
        measure(name, "jonction", keys.getOrNull(next), drawn.junction, exact) { _, _ -> 0f }
    }

    /**
     * Compare une hauteur du trait [shown] au centre réel de la perle [key], si elle est visible. [gap] : de combien le
     * trait s'arrête avant la perle (positif = trou).
     */
    private fun measure(
        name: String,
        what: String,
        key: String?,
        shown: Float,
        exact: Boolean,
        gap: (Float, Float) -> Float,
    ) {
        val bead = actualCenter(key) ?: return
        val density = compose.density.density
        val tolerance = TOLERANCE_DP * density
        val error = abs(shown - bead)
        samples++
        if (exact) worst = maxOf(worst, error / density)
        if (gap(shown, bead) > tolerance) failures += "$name : trou, $what à ${error / density} dp"
        if (exact && error > tolerance) failures += "$name : $what à ${error / density} dp"
    }

    /** Centre réel de la perle d'une ligne visible, transformations de calque comprises (px, repère de la liste). */
    private fun actualCenter(key: String?): Float? {
        val visible = listState.layoutInfo.visibleItemsInfo.any { it.key == key }
        val gutter = coords[key]?.takeIf { visible && it.isAttached } ?: return null
        val origin = list?.positionInRoot()?.y ?: 0f
        return gutter.positionInRoot().y + gutter.size.height / 2f - origin
    }

    // endregion

    @Composable
    private fun Ticket() {
        listState = rememberLazyListState()
        scope = rememberCoroutineScope()
        track = rememberThreadTrackState()
        val keys = rows.value
        val path = ThreadPath(keys = keys, startIndex = 0, next = next, style = ThreadStyle.Solid)
        ParcoursesTheme(darkTheme = false, accessibility = AccessibilityPreferences()) {
            CompositionLocalProvider(LocalThreadTrack provides track) {
                LazyColumn(
                    Modifier.fillMaxSize().onPlaced { list = it }.threadTrack(track, listState, path),
                    state = listState,
                ) {
                    items(keys, key = { it }) { key ->
                        Row(
                            Modifier
                                .animateItem(
                                    fadeInSpec = TicketMotion.fade(false),
                                    placementSpec = TicketMotion.reorder(false),
                                    fadeOutSpec = TicketMotion.fade(false),
                                ).fillMaxWidth()
                                .height(56.dp)
                                .padding(start = ThreadLayout.start),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            ThreadGutter(key, Modifier.onPlaced { coords[key] = it }) { ThreadBead(Bead.Idle) }
                            RowLane { BasicText(key) }
                        }
                    }
                }
            }
        }
    }

    /** Robolectric garde toutes les sections de trace sans limite : on coupe et on vide, sinon le tas sature. */
    private fun quietTrace() {
        ShadowTrace.reset()
        ShadowTrace.setEnabled(false)
    }

    private companion object {
        const val FRAME_MS = 16L
        const val SETTLE_FRAMES = 45
        const val SCROLL_FRAMES = 30
        const val TOLERANCE_DP = 1f
        const val MIN_SAMPLES = 300
        val SORT = listOf(0, 1, 2, 7, 8, 9, 3, 4, 5, 6, 11, 12, 13, 14, 19, 18, 17, 16, 15, 10)
    }
}

/** Active les vrais parcours de dessin de Robolectric (rendu matériel, listes d'affichage) avant l'activité. */
private class RealDrawTraversals : TestWatcher() {
    override fun starting(description: Description) {
        ShadowView.setUseRealDrawTraversals(true)
    }

    override fun finished(description: Description) {
        ShadowView.setUseRealDrawTraversals(false)
    }
}
