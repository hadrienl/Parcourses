package fr.parcourses.feature.shopping.proto

import android.app.Activity
import android.content.ContextWrapper
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import android.view.View
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onLayoutRectChanged
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.TicketMotion
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
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
import kotlin.math.max
import kotlin.math.roundToInt

// Prototype du lot 0 de #115 (option B, partie Android) : le trait est dessiné une seule fois par un `drawBehind` posé
// sur la `LazyColumn`, à partir des positions des perles première, suivante et dernière publiées dans un
// `ThreadTrackState`. On compare plusieurs sources de position, image par image, pendant un tri, des départs et un
// défilement rapide. Hors de l'app : copié temporairement dans `feature/shopping` par `run.sh`, puis supprimé.
//
// Fidélité du pipeline : Robolectric en graphismes natifs avec les vrais parcours de dessin (`HardwareRenderer`,
// listes d'affichage) et un Choreographer en pause, avancé de 16 ms par image. Une image = la trame Compose
// (animations, recomposition) puis le parcours de la vue (mise en page, rappels de position, dessin), comme sur un
// appareil. La capture recopie la dernière image rendue, sans redessiner.

/** Source de la position verticale des perles publiée vers le trait. */
private enum class Source(val label: String) {
    Placed("onPlaced"),
    Global("onGloballyPositioned"),
    LayoutRect("onLayoutRectChanged(0, 0)"),
    LayoutRectDefault("onLayoutRectChanged(0, 64) par défaut"),
    Live("coordonnées lues au dessin"),
}

private enum class Role { First, Next, Last }

/** Phase du test pendant laquelle le trait est dessiné : seuls les dessins de [Frame] correspondent à l'écran. */
private enum class Phase { Setup, Frame, Capture, Measure }

private data class RowData(
    val key: String,
)

/** Marqueur du trait : la ligne qui le porte et la hauteur publiée de sa perle (px, repère racine). */
private data class Marker(
    val key: String,
    val y: Float?,
)

/** État du trait : trois marqueurs observables, lus en phase de dessin. */
private class ThreadTrackState {
    val slots: Map<Role, MutableState<Marker?>> = Role.entries.associateWith { mutableStateOf(null) }

    fun assign(
        role: Role,
        key: String?,
        initialY: Float?,
    ) {
        val slot = slots.getValue(role)
        if (slot.value?.key != key) slot.value = key?.let { Marker(it, initialY) }
    }

    fun publish(
        key: String,
        y: Float?,
    ) {
        for (slot in slots.values) {
            val marker = slot.value
            if (marker?.key == key && marker.y != y) slot.value = marker.copy(y = y)
        }
    }
}

/** Sonde d'une ligne : registre de coordonnées (vivantes) et compteurs de rappels. */
private class RowProbe(
    val key: String,
) {
    var coords: LayoutCoordinates? = null
    var gutterPlaced = 0
    var itemPlaced = 0
    var callbacks = 0
    var published: Float? = null

    // État à la fin de l'image précédente, pour détecter un déplacement sans rappel.
    var lastActual: Float? = null
    var lastGutterPlaced = 0
    var lastCallbacks = 0
}

/** Ce que le trait a réellement dessiné (px, repère de la liste) et avec quelles valeurs. */
private class DrawRecord(
    val frame: Int,
    val phase: Phase,
    val top: Float,
    val junction: Float,
    val bottom: Float,
    val published: Map<String, Float?>,
)

private class Env(
    val source: Source,
) {
    val rows = mutableStateOf(emptyList<RowData>())
    var nextIndex = NEXT_INDEX
    val track = ThreadTrackState()
    val probes = HashMap<String, RowProbe>()
    var list: LayoutCoordinates? = null
    lateinit var listState: LazyListState
    lateinit var scope: CoroutineScope
    var view: View? = null
    var frame = 0
    var phase = Phase.Setup
    val draws = ArrayList<DrawRecord>()

    fun listTop(): Float = list?.takeIf { it.isAttached }?.positionInRoot()?.y ?: 0f

    fun listHeight(): Float = list?.takeIf { it.isAttached }?.size?.height?.toFloat() ?: 0f

    /** Position réelle du centre de la perle, à l'instant, transformations de calque comprises (px, racine). */
    fun actualY(key: String): Float? =
        probes[key]?.coords?.takeIf { it.isAttached }?.let { it.positionInRoot().y + it.size.height / 2f }

    fun publish(
        probe: RowProbe,
        y: Float,
    ) {
        probe.published = y
        probe.callbacks++
        track.publish(probe.key, y)
    }
}

private class Stats(
    val source: Source,
    val scenario: String,
) {
    var frames = 0
    var drawsInFrames = 0
    var drawsInCapture = 0
    var framesMarkerMovedWithoutDraw = 0
    val markerErr = ArrayList<Float>()
    var framesOverTolerance = 0
    val allErr = ArrayList<Float>()
    var movedRows = 0
    var movedWithoutGutterPlaced = 0
    var movedWithoutCallback = 0
    var pixelFrames = 0
    var pixelGapFrames = 0
    var pixelMaxGap = 0f
    var pixelMaxOvershoot = 0f
    var pixelMaxJunction = 0f
    val lagTrace = ArrayList<String>()
    var framesBeadMovedWithoutDraw = 0
    val staleTrace = ArrayList<String>()
}

private val Accent = Color(0xFFFF0000)
private val Ahead = Color(0xFF00FF00)
private val BeadColor = Color(0xFF0000FF)
private val GutterStart = 16.dp
private val Gutter = 28.dp
private val BeadRadius = 7.dp
private val TrackWidth = 2.dp
private val RowHeight = 56.dp
private const val FRAME_MS = 16L
private const val NEXT_INDEX = 3
private const val TOLERANCE_DP = 7f

// Tri : plusieurs lignes permutées ; la dernière (r10) vient de l'index 10, la suivante (index 3) devient r7.
private val Permutation = listOf(0, 1, 2, 7, 8, 9, 3, 4, 5, 6, 11, 12, 13, 14, 19, 18, 17, 16, 15, 10)

@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w360dp-h1240dp-xhdpi")
class ThreadTrackProtoTest {
    private val compose = createComposeRule()

    @get:Rule
    val rules: RuleChain = RuleChain.outerRule(RealDrawTraversals()).around(compose)

    @Test
    fun placed() = measureSource(Source.Placed)

    @Test
    fun globallyPositioned() = measureSource(Source.Global)

    @Test
    fun layoutRectChanged() = measureSource(Source.LayoutRect)

    @Test
    fun layoutRectChangedDefault() = measureSource(Source.LayoutRectDefault)

    @Test
    fun liveCoordinates() = measureSource(Source.Live)

    @Test
    fun sectionKeyPrefixed() = sectionKeys(prefixed = true)

    @Test
    fun sectionKeyShared() = sectionKeys(prefixed = false)

    // region Scénarios

    private fun measureSource(source: Source) {
        val env = Env(source)
        env.rows.value = (0 until 20).map { RowData("r$it") }
        start(env)
        val density = compose.density.density
        val results = ArrayList<Stats>()

        results += scenario(env, "a. tri (20 lignes, dernière permutée)", 50) {
            env.rows.value = Permutation.map { RowData("r$it") }
        }
        results += scenario(env, "b. départ première + dernière", 45) {
            env.rows.value = env.rows.value.drop(1).dropLast(1)
        }
        // Défilement : 100 lignes (5 600 dp, ~4,5 écrans), installées puis stabilisées hors mesure.
        env.rows.value = (0 until 100).map { RowData("c$it") }
        env.nextIndex = 10
        Snapshot.sendApplyNotifications()
        repeat(30) { frame(env, null) }
        val step = 96f * density
        results += scenario(env, "c1. scrollBy 96 dp/image, 30 aller + 30 retour", 66) {
            env.scope.launch {
                repeat(30) {
                    withFrameNanos { }
                    env.listState.scrollBy(step)
                }
                repeat(30) {
                    withFrameNanos { }
                    env.listState.scrollBy(-step)
                }
            }
        }
        val far = 4000f * density
        results += scenario(env, "c2. animateScrollBy 4000 dp/700 ms, aller-retour", 100) {
            env.scope.launch {
                env.listState.animateScrollBy(far, tween(700, easing = LinearEasing))
                env.listState.animateScrollBy(-far, tween(700, easing = LinearEasing))
            }
        }
        results.forEach { report(it) }
    }

    /** Une ligne qui change de section : clé préfixée (sort et entre en fondu) ou clé partagée (glisse). */
    private fun sectionKeys(prefixed: Boolean) {
        val env = Env(Source.Placed)
        fun basket(id: String) = RowData(if (prefixed) "basket-$id" else id)
        val toBuy = (0..5).map { RowData("r$it") }
        val header = RowData("basket-header")
        env.rows.value = toBuy + header + basket("b0")
        start(env)
        val density = compose.density.density
        val oldKey = "r2"
        val newKey = if (prefixed) "basket-r2" else "r2"
        val oldPlace = checkNotNull(env.actualY(oldKey)).roundToInt()
        env.rows.value = toBuy.filter { it.key != oldKey } + header + basket("r2") + basket("b0")
        Snapshot.sendApplyNotifications()
        val label = if (prefixed) "préfixée" else "partagée"
        val keys = listOf(oldKey, newKey).distinct()
        val traces = keys.associateWith { ArrayList<Pair<Float?, Float?>>() }
        repeat(16) { i ->
            frame(env, null)
            val bitmap = capture(env)
            val top = env.listTop()
            println(
                "P115 KEY | clé $label | image ${i + 1} | ancienne place | alpha=%.2f, sondes=%s"
                    .format(beadAlpha(bitmap, oldPlace, density), env.probes.keys.filter { it.endsWith("r2") }),
            )
            // Une même clé avant et après n'est qu'un seul nœud : on lit le dernier connu.
            for (key in keys) {
                val y = env.actualY(key)
                val alpha = y?.let { beadAlpha(bitmap, it.roundToInt(), density) }
                traces.getValue(key) += (y?.let { (it - top) / density }) to alpha
                println(
                    "P115 KEY | clé $label | image ${i + 1} | $key | " +
                        (y?.let { "y=%.1f dp, alpha=%.2f".format((it - top) / density, alpha) } ?: "absente"),
                )
            }
        }
        for (key in keys) {
            val ys = traces.getValue(key).mapNotNull { it.first }
            val alphas = traces.getValue(key).mapNotNull { it.second }
            val travel = if (ys.isEmpty()) 0f else ys.max() - ys.min()
            println(
                "P115 KEYSUM | clé $label | $key | images présentes=${ys.size} | déplacement=%.1f dp | alpha %.2f → %.2f"
                    .format(travel, alphas.firstOrNull() ?: Float.NaN, alphas.lastOrNull() ?: Float.NaN),
            )
        }
    }

    // endregion

    // region Pilotage image par image

    private fun start(env: Env) {
        compose.mainClock.autoAdvance = false
        quietTrace()
        compose.setContent { ProtoList(env) }
        println("P115 DBG ${env.source} contenu posé, dessins=${env.draws.size}")
        // Choreographer en pause : une vsync seulement quand l'horloge avance de 16 ms, donc un parcours par image.
        ShadowChoreographer.setPaused(true)
        ShadowChoreographer.setFrameDelay(Duration.ofMillis(FRAME_MS))
        repeat(20) { frame(env, null) }
    }

    /** Une image : trame Compose (animations, recomposition), puis vsync (mise en page, rappels, dessin). */
    private fun frame(
        env: Env,
        stats: Stats?,
    ) {
        env.frame++
        quietTrace()
        val before = env.draws.size
        env.phase = Phase.Frame
        compose.mainClock.advanceTimeByFrame()
        // 17 ms : la vsync demandée à 16 ms tombe dans l'intervalle, celle que le dessin redemande (32 ms) non.
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(FRAME_MS + 1))
        if (env.frame % 25 == 0) println("P115 DBG ${env.source} image ${env.frame}, dessins=${env.draws.size}")
        env.phase = Phase.Measure
        if (stats != null) {
            stats.drawsInFrames += env.draws.size - before
            record(env, stats, capture(env, stats))
        }
        for (probe in env.probes.values) {
            probe.lastActual = env.actualY(probe.key)
            probe.lastGutterPlaced = probe.gutterPlaced
            probe.lastCallbacks = probe.callbacks
        }
    }

    /** Robolectric garde toutes les sections de trace sans limite : on coupe et on vide, sinon le tas sature. */
    private fun quietTrace() {
        ShadowTrace.reset()
        ShadowTrace.setEnabled(false)
    }

    /**
     * Copie de la dernière image rendue (PixelCopy sur la fenêtre), sans `captureToImage` : celle-ci attend une
     * vsync, qui ne vient jamais avec un Choreographer en pause. Ne fait avancer ni l'horloge ni le dessin.
     */
    private fun capture(
        env: Env,
        stats: Stats? = null,
    ): Bitmap {
        env.phase = Phase.Capture
        val before = env.draws.size
        val view = checkNotNull(env.view)
        var context = view.context
        while (context !is Activity) context = (context as ContextWrapper).baseContext
        val origin = IntArray(2).also { view.getLocationInWindow(it) }
        val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
        var result = -1
        PixelCopy.request(
            context.window,
            Rect(origin[0], origin[1], origin[0] + view.width, origin[1] + view.height),
            bitmap,
            { result = it },
            Handler(Looper.getMainLooper()),
        )
        shadowOf(Looper.getMainLooper()).idle()
        check(result == PixelCopy.SUCCESS) { "PixelCopy : $result" }
        stats?.let { it.drawsInCapture += env.draws.size - before }
        env.phase = Phase.Measure
        return bitmap
    }

    private fun scenario(
        env: Env,
        name: String,
        frames: Int,
        action: () -> Unit,
    ): Stats {
        val stats = Stats(env.source, name)
        action()
        Snapshot.sendApplyNotifications()
        repeat(frames) { frame(env, stats) }
        return stats
    }

    // endregion

    // region Mesure

    private fun record(
        env: Env,
        stats: Stats,
        bitmap: Bitmap,
    ) {
        val density = compose.density.density
        stats.frames++
        val top = env.listTop()
        val height = env.listHeight()
        // Image à l'écran : dernier dessin d'une vraie image (pas celui d'une capture, s'il y en avait).
        val drawn = env.draws.lastOrNull { it.phase != Phase.Capture } ?: env.draws.lastOrNull() ?: return
        val drewThisFrame = drawn.frame == env.frame
        val index = stats.frames

        fun visible(y: Float?) = y != null && y - top in 0f..height

        // Écart entre ce que le trait affiche et la perle réelle, pour chaque marqueur visible.
        var markerMoved = false
        var worst = 0f
        val visibleMarkers = HashMap<Role, Float>()
        for (role in Role.entries) {
            val key = env.track.slots.getValue(role).value?.key ?: continue
            val actual = env.actualY(key)
            if (!visible(actual)) continue
            actual!!
            visibleMarkers[role] = actual - top
            val previous = env.probes[key]?.lastActual
            if (previous != null && abs(previous - actual) > 0.5f) markerMoved = true
            val shown =
                when (role) {
                    Role.First -> drawn.top
                    Role.Next -> drawn.junction
                    Role.Last -> drawn.bottom
                }
            val err = abs(shown - (actual - top)) / density
            stats.markerErr += err
            worst = max(worst, err)
            if (err > 0.5f && stats.lagTrace.size < 10) {
                stats.lagTrace += "i$index:${role.name}=%.1f%s".format(err, if (drewThisFrame) "" else "(sans dessin)")
            }
        }
        if (worst > TOLERANCE_DP) stats.framesOverTolerance++
        if (markerMoved && !drewThisFrame) stats.framesMarkerMovedWithoutDraw++

        // Toutes les perles visibles : valeur publiée par la source au moment du dessin contre la position réelle. Les
        // éléments gardés hors écran (cache, préchargement) sont exclus : seuls ceux de `visibleItemsInfo` comptent.
        val shownKeys = env.listState.layoutInfo.visibleItemsInfo.map { it.key }.toSet()
        var staleRows = 0
        var staleMax = 0f
        var beadMoved = false
        for (probe in env.probes.values) {
            val actual = env.actualY(probe.key)
            if (probe.key !in shownKeys || !visible(actual)) continue
            actual!!
            if (env.source != Source.Live) {
                drawn.published[probe.key]?.let {
                    val err = abs(it - actual) / density
                    stats.allErr += err
                    if (err > 0.5f) {
                        staleRows++
                        staleMax = max(staleMax, err)
                    }
                }
            }
            val previous = probe.lastActual ?: continue
            if (abs(previous - actual) <= 0.5f) continue
            beadMoved = true
            stats.movedRows++
            if (probe.gutterPlaced == probe.lastGutterPlaced) stats.movedWithoutGutterPlaced++
            if (env.source != Source.Live && probe.callbacks == probe.lastCallbacks) stats.movedWithoutCallback++
        }

        if (beadMoved && !drewThisFrame) stats.framesBeadMovedWithoutDraw++
        if (staleRows > 0 && stats.staleTrace.size < 8) {
            stats.staleTrace +=
                "i$index:%d perles, %.1f dp, %s, marqueurs visibles=%s".format(
                    staleRows,
                    staleMax,
                    if (drewThisFrame) "dessin" else "sans dessin",
                    visibleMarkers.keys.joinToString("+") { it.name }.ifEmpty { "aucun" },
                )
        }
        pixelCheck(bitmap, env, visibleMarkers, density, stats)
    }

    /**
     * Vérification aux pixels de la dernière image rendue, dans la colonne du trait. Une perle (disque plein de 14 dp)
     * masque le trait sur ±7 dp : on relève un trou (le trait s'arrête avant la perle), un dépassement (le trait va
     * au-delà de la perle) et une jonction accent / à parcourir visible hors de la perle suivante.
     */
    private fun pixelCheck(
        bitmap: Bitmap,
        env: Env,
        markers: Map<Role, Float>,
        density: Float,
        stats: Stats,
    ) {
        val x = ((GutterStart + Gutter / 2).value * density).roundToInt()
        val top = env.listTop().roundToInt()
        val bottom = minOf(bitmap.height, top + env.listHeight().roundToInt())
        val paper = BooleanArray(maxOf(0, bottom - top))
        var firstTrack = -1
        var lastTrack = -1
        var lastRed = -1
        var firstGreen = -1
        for (y in top until bottom) {
            val c = bitmap.getPixel(x, y)
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            val red = r > 200 && g < 80 && b < 80
            val green = g > 200 && r < 80 && b < 80
            paper[y - top] = r > 230 && g > 230 && b > 230
            if (red || green) {
                if (firstTrack < 0) firstTrack = y - top
                lastTrack = y - top
            }
            if (red) lastRed = y - top
            if (green && firstGreen < 0) firstGreen = y - top
        }
        if (firstTrack < 0) return
        stats.pixelFrames++
        val radius = BeadRadius.value * density
        val slack = 1.5f
        // Un trou, c'est du papier entre le bout du trait et la perle (pas une autre perle qui croise le trait).
        fun paperBetween(
            from: Float,
            to: Float,
        ): Int = (from.roundToInt().coerceAtLeast(0) until to.roundToInt().coerceAtMost(paper.size)).count { paper[it] }
        var gap = 0f
        markers[Role.First]?.let { c ->
            if (firstTrack > c + radius + slack) gap = max(gap, paperBetween(c + radius + slack, firstTrack.toFloat()).toFloat())
            if (firstTrack < c - radius - slack) {
                stats.pixelMaxOvershoot = max(stats.pixelMaxOvershoot, ((c - radius) - firstTrack) / density)
            }
        }
        markers[Role.Last]?.let { c ->
            if (lastTrack < c - radius - slack) gap = max(gap, paperBetween(lastTrack + 1f, c - radius - slack).toFloat())
            if (lastTrack > c + radius + slack) {
                stats.pixelMaxOvershoot = max(stats.pixelMaxOvershoot, (lastTrack - (c + radius)) / density)
            }
        }
        markers[Role.Next]?.let { c ->
            var dev = 0f
            if (lastRed >= 0 && lastRed > c + radius + slack) dev = max(dev, lastRed - (c + radius))
            if (firstGreen >= 0 && firstGreen < c - radius - slack) dev = max(dev, (c - radius) - firstGreen)
            stats.pixelMaxJunction = max(stats.pixelMaxJunction, dev / density)
        }
        if (gap > 0f) {
            stats.pixelGapFrames++
            stats.pixelMaxGap = max(stats.pixelMaxGap, gap / density)
        }
    }

    /** Opacité d'une perle lue à côté du trait, sur fond blanc : 1 − R / 255. */
    private fun beadAlpha(
        bitmap: Bitmap,
        y: Int,
        density: Float,
    ): Float {
        val x = ((GutterStart + Gutter / 2).value * density + 5 * density).roundToInt()
        if (y !in 0 until bitmap.height) return Float.NaN
        val r = (bitmap.getPixel(x, y) shr 16) and 0xFF
        return 1f - r / 255f
    }

    private fun report(s: Stats) {
        fun List<Float>.maxOr() = if (isEmpty()) "-" else "%.2f".format(max())

        fun List<Float>.meanOr() = if (isEmpty()) "-" else "%.2f".format(average())
        println(
            "P115 ROW | ${s.source.label} | ${s.scenario} | ${s.frames} | ${s.drawsInFrames} | ${s.drawsInCapture} | " +
                "${s.framesMarkerMovedWithoutDraw} | ${s.markerErr.maxOr()} | ${s.markerErr.meanOr()} | " +
                "${s.markerErr.size} | ${s.framesOverTolerance} | ${s.allErr.maxOr()} | ${s.allErr.meanOr()} | " +
                "${s.movedRows} | ${s.movedWithoutGutterPlaced} | " +
                (if (s.source == Source.Live) "-" else "${s.movedWithoutCallback}") + " | " +
                "${s.pixelFrames} | ${s.pixelGapFrames} | %.1f | %.1f | %.1f".format(
                    s.pixelMaxGap,
                    s.pixelMaxOvershoot,
                    s.pixelMaxJunction,
                ),
        )
        println(
            "P115 STALE | ${s.source.label} | ${s.scenario} | images où une perle bouge sans dessin=" +
                "${s.framesBeadMovedWithoutDraw} | ${s.staleTrace.joinToString(" ; ")}",
        )
        if (s.lagTrace.isNotEmpty()) {
            println("P115 LAG | ${s.source.label} | ${s.scenario} | ${s.lagTrace.joinToString(" ")}")
        }
    }

    // endregion
}

// region Liste prototype

@Composable
private fun ProtoList(env: Env) {
    val listState = rememberLazyListState()
    env.listState = listState
    env.scope = rememberCoroutineScope()
    env.view = LocalView.current
    val rows = env.rows.value
    // Rôles du trait : premier, suivant et dernier marqueur, d'après l'ordre affiché.
    SideEffect {
        fun initial(key: String?) = key?.let { env.probes[it]?.published }
        val keys = rows.map { it.key }
        env.track.assign(Role.First, keys.firstOrNull(), initial(keys.firstOrNull()))
        env.track.assign(Role.Next, keys.getOrNull(env.nextIndex), initial(keys.getOrNull(env.nextIndex)))
        env.track.assign(Role.Last, keys.lastOrNull(), initial(keys.lastOrNull()))
    }
    // Calque propre, comme sous un hôte de navigation : le dessin de la liste n'est refait que s'il est invalidé.
    Box(Modifier.fillMaxSize().graphicsLayer().background(Color.White)) {
        LazyColumn(
            state = listState,
            modifier =
                Modifier
                    .fillMaxSize()
                    .onPlaced { env.list = it }
                    .drawBehind { drawTrack(env) },
        ) {
            items(rows, key = { it.key }) { row ->
                ProtoRow(
                    row,
                    env,
                    Modifier.animateItem(
                        fadeInSpec = TicketMotion.fade(false),
                        placementSpec = TicketMotion.reorder(false),
                        fadeOutSpec = TicketMotion.fade(false),
                    ),
                )
            }
        }
    }
}

@Composable
private fun ProtoRow(
    row: RowData,
    env: Env,
    modifier: Modifier,
) {
    val probe = remember(row.key) { RowProbe(row.key) }
    DisposableEffect(row.key) {
        env.probes[row.key] = probe
        onDispose {
            if (env.probes[row.key] === probe) env.probes.remove(row.key)
            env.track.publish(row.key, null)
        }
    }
    Row(
        modifier
            .fillMaxWidth()
            .height(RowHeight)
            .onPlaced { probe.itemPlaced++ }
            .padding(start = GutterStart),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Gouttière : porte la perle et publie sa position selon la source étudiée.
        Box(
            Modifier
                .size(Gutter)
                .onPlaced {
                    probe.coords = it
                    probe.gutterPlaced++
                }.then(positionSource(env, probe))
                .drawBehind { drawCircle(BeadColor, BeadRadius.toPx()) },
        )
        BasicText(row.key, Modifier.padding(start = 16.dp))
    }
}

private fun positionSource(
    env: Env,
    probe: RowProbe,
): Modifier =
    when (env.source) {
        Source.Placed -> Modifier.onPlaced { env.publish(probe, it.positionInRoot().y + it.size.height / 2f) }
        Source.Global -> Modifier.onGloballyPositioned { env.publish(probe, it.positionInRoot().y + it.size.height / 2f) }
        Source.LayoutRect ->
            Modifier.onLayoutRectChanged(throttleMillis = 0, debounceMillis = 0) {
                env.publish(probe, it.positionInRoot.y + it.height / 2f)
            }
        Source.LayoutRectDefault -> Modifier.onLayoutRectChanged { env.publish(probe, it.positionInRoot.y + it.height / 2f) }
        Source.Live -> Modifier
    }

/** Le trait : du premier au dernier marqueur, en accent jusqu'à la perle suivante. Lit l'état en phase de dessin. */
private fun DrawScope.drawTrack(env: Env) {
    val origin = env.listTop()
    val ys =
        Role.entries.associateWith { role ->
            val marker = env.track.slots.getValue(role).value
            when {
                marker == null -> null
                env.source == Source.Live -> env.actualY(marker.key)
                else -> marker.y
            }?.minus(origin)
        }
    val top = ys[Role.First] ?: 0f
    val bottom = max(top, ys[Role.Last] ?: size.height)
    // Perle suivante hors écran : au-dessus, tout le visible est à parcourir ; au-dessous, tout est parcouru.
    val junction =
        (ys[Role.Next] ?: if (env.nextIndex < env.listState.firstVisibleItemIndex) top else bottom).coerceIn(top, bottom)
    val x = (GutterStart + Gutter / 2).toPx()
    val width = TrackWidth.toPx()
    drawLine(Accent, Offset(x, top), Offset(x, junction), width)
    drawLine(Ahead, Offset(x, junction), Offset(x, bottom), width)
    env.draws += DrawRecord(env.frame, env.phase, top, junction, bottom, env.probes.mapValues { it.value.published })
}

// endregion

/** Active les vrais parcours de dessin de Robolectric (rendu matériel, listes d'affichage) avant l'activité. */
private class RealDrawTraversals : TestWatcher() {
    override fun starting(description: Description) {
        ShadowView.setUseRealDrawTraversals(true)
    }

    override fun finished(description: Description) {
        ShadowView.setUseRealDrawTraversals(false)
    }
}
