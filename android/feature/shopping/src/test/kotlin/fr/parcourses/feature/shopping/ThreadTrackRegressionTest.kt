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
 * appareil. Tolérance : 1 dp ; aucune perle du fil hors du trait, même celle qui s'efface après l'avoir quitté.
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

    /** Perles qui viennent de quitter le fil : leur dernière place, vérifiée le temps de leur fondu. */
    private val fading = HashMap<String, Float>()
    private var fadingFrames = 0

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

        println("ThreadTrackRegressionTest : $samples bouts et jonctions vérifiés, écart max $worst dp hors fondus")
        assertTrue(failures.take(12).joinToString("\n"), failures.isEmpty())
        // Garde-fou : un trait jamais dessiné ne doit pas passer pour un trait exact.
        assertTrue("trop peu de marqueurs vérifiés : $samples", samples >= MIN_SAMPLES)
    }

    /**
     * Liste qui n'anime pas ses lignes (écran Liste) : ni bout tenu ni jonction qui coule, le trait suit les perles dès
     * l'image du changement.
     */
    @Test
    fun withoutAnimationTheTrackChangesInTheSameFrame() {
        compose.mainClock.autoAdvance = false
        quietTrace()
        compose.setContent { Ticket(animated = false) }
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(FRAME_MS))
        repeat(10) { frame("repos", exact = true) }
        // Suppression de la dernière ligne, puis de la première : la perle suivante (index 3) change aussi.
        rows.value = rows.value.dropLast(1)
        Snapshot.sendApplyNotifications()
        repeat(4) { frame("dernière supprimée", exact = true) }
        rows.value = rows.value.drop(1)
        Snapshot.sendApplyNotifications()
        repeat(4) { frame("première supprimée", exact = true) }

        assertTrue(failures.take(12).joinToString("\n"), failures.isEmpty())
        assertTrue("trop peu de mesures : $samples", samples >= 30)
    }

    /** Un changement de la liste, puis les images qui suivent : écarts tolérés seulement le temps des fondus. */
    private fun change(
        name: String,
        action: () -> Unit,
    ) {
        val before = rows.value.associateWith { actualCenter(it) }
        action()
        Snapshot.sendApplyNotifications()
        fading.clear()
        before.forEach { (key, y) -> if (y != null && key !in rows.value) fading[key] = y }
        // Une perle qui part s'efface sur place en `TicketMotion.FADE_MS` : on la suit tant qu'elle est sûrement visible.
        fadingFrames = TicketMotion.FADE_MS / FRAME_MS.toInt() - 1
        // Bouts tenus (fondu) et jonction qui coule (coche) : seules les perles sont vérifiées pendant ce temps.
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
        val density = compose.density.density
        val tolerance = TOLERANCE_DP * density
        val keys = rows.value
        val beads = keys.mapNotNull { key -> actualCenter(key)?.let { key to it } }.toMap()
        // Aucune perle du fil hors du trait, ni celles qui s'effacent après avoir quitté le fil.
        val onScreen = if (fadingFrames-- > 0) beads + fading else beads
        onScreen.forEach { (key, y) ->
            if (y < drawn.top - tolerance || y > drawn.bottom + tolerance) {
                failures += "$name : perle $key hors du trait (${y / density} dp, trait ${drawn.top / density} à " +
                    "${drawn.bottom / density} dp)"
            }
        }
        // Bouts : enveloppe des perles visibles du fil quand le premier ou le dernier marqueur est à l'écran.
        if (keys.firstOrNull() in beads) measure(name, "bout haut", drawn.top, beads.values.min(), exact)
        if (keys.lastOrNull() in beads) measure(name, "bout bas", drawn.bottom, beads.values.max(), exact)
        // Jonction : sur la perle suivante une fois la coulée finie.
        keys.getOrNull(next)?.let { beads[it] }?.let { measure(name, "jonction", drawn.junction, it, exact) }
    }

    /** Compare une hauteur du trait [shown] à celle attendue [expected], hors fondus et coulées ([exact]). */
    private fun measure(
        name: String,
        what: String,
        shown: Float,
        expected: Float,
        exact: Boolean,
    ) {
        val density = compose.density.density
        val error = abs(shown - expected)
        samples++
        if (exact) worst = maxOf(worst, error / density)
        if (exact && error > TOLERANCE_DP * density) failures += "$name : $what à ${error / density} dp"
    }

    /** Centre réel de la perle d'une ligne visible, transformations de calque comprises (px, repère de la liste). */
    private fun actualCenter(key: String?): Float? {
        val visible = listState.layoutInfo.visibleItemsInfo.any { it.key == key }
        // Une ligne qui sort de l'écran garde des coordonnées figées : seules les lignes visibles comptent.
        val gutter = coords[key]?.takeIf { visible && it.isAttached } ?: return null
        val origin = list?.positionInRoot()?.y ?: 0f
        val height = list?.size?.height?.toFloat() ?: 0f
        // Perle coupée par un bord : le trait s'arrête au bord, on ne la compte pas.
        return (gutter.positionInRoot().y + gutter.size.height / 2f - origin).takeIf { it in 0f..height }
    }

    // endregion

    @Composable
    private fun Ticket(animated: Boolean = true) {
        listState = rememberLazyListState()
        scope = rememberCoroutineScope()
        track = rememberThreadTrackState()
        val keys = rows.value
        val path = ThreadPath(keys = keys, startIndex = 0, next = next, style = ThreadStyle.Solid)
        ParcoursesTheme(darkTheme = false, accessibility = AccessibilityPreferences()) {
            CompositionLocalProvider(LocalThreadTrack provides track) {
                LazyColumn(
                    Modifier.fillMaxSize().onPlaced { list = it }.threadTrack(track, listState, path, animated),
                    state = listState,
                ) {
                    items(keys, key = { it }) { key ->
                        Row(
                            Modifier
                                .then(
                                    if (animated) {
                                        Modifier.animateItem(
                                            fadeInSpec = TicketMotion.fade(false),
                                            placementSpec = TicketMotion.reorder(false),
                                            fadeOutSpec = TicketMotion.fade(false),
                                        )
                                    } else {
                                        Modifier
                                    },
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
