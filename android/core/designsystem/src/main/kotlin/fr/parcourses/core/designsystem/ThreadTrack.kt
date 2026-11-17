package fr.parcourses.core.designsystem

import androidx.compose.animation.core.animate
import androidx.compose.foundation.lazy.LazyListItemInfo
import androidx.compose.foundation.lazy.LazyListLayoutInfo
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.layout.onLayoutRectChanged
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import kotlinx.coroutines.delay
import kotlin.math.abs

// region Tronçons du trait (fonction pure, mêmes cas sur iOS)

/** Place d'un marqueur du fil (premier, suivant, dernier) par rapport à la partie visible de la liste. */
sealed interface MarkerPlace {
    /** Visible : centre de la perle ou du nœud, en px dans le repère de la liste. */
    data class Visible(
        val y: Float,
    ) : MarkerPlace

    /** Au-dessus du bord haut de la liste. */
    data object Above : MarkerPlace

    /** Au-dessous du bord bas de la liste. */
    data object Below : MarkerPlace

    /** Pas de marqueur : fil vide, ou pas de perle suivante quand tout est parcouru. */
    data object Absent : MarkerPlace
}

/** Le trait visible : parcouru (accent) de [top] à [junction], à parcourir de [junction] à [bottom] (px, liste). */
@Immutable
data class ThreadTrackSegments(
    val top: Float,
    val junction: Float,
    val bottom: Float,
)

/**
 * Tronçons du trait d'après ses trois marqueurs et la hauteur visible [height] : du premier au dernier marqueur, ramené
 * aux bords de la liste quand un bout est hors écran ; parcouru jusqu'à la perle suivante. Perle suivante au-dessus de
 * l'écran : tout le visible est à parcourir ; au-dessous, ou absente (tout est pris) : tout est parcouru. `null` quand
 * aucun trait n'est visible (fil vide, d'un seul arrêt, ou entièrement hors écran).
 */
fun threadTrackSegments(
    first: MarkerPlace,
    next: MarkerPlace,
    last: MarkerPlace,
    height: Float,
): ThreadTrackSegments? {
    val top =
        when (first) {
            is MarkerPlace.Visible -> first.y.coerceIn(0f, height)
            MarkerPlace.Above -> 0f
            MarkerPlace.Below, MarkerPlace.Absent -> null
        }
    val bottom =
        when (last) {
            is MarkerPlace.Visible -> last.y.coerceIn(0f, height)
            MarkerPlace.Below -> height
            MarkerPlace.Above, MarkerPlace.Absent -> null
        }
    if (top == null || bottom == null || bottom <= top) return null
    val junction =
        when (next) {
            is MarkerPlace.Visible -> next.y
            MarkerPlace.Above -> top
            MarkerPlace.Below, MarkerPlace.Absent -> bottom
        }.coerceIn(top, bottom)
    return ThreadTrackSegments(top, junction, bottom)
}

// endregion

// region Trait unique de la liste

/**
 * Le fil d'une liste, vu par la liste : les clés `LazyColumn` de ses arrêts (titres de rayon et articles) dans l'ordre,
 * l'index `LazyColumn` du premier, la position de la perle suivante ([keys].size quand tout est parcouru) et le style.
 */
@Immutable
data class ThreadPath(
    val keys: List<Any>,
    val startIndex: Int,
    val next: Int,
    val style: ThreadStyle,
) {
    internal val nextKey: Any? get() = keys.getOrNull(next)

    /** Clés des arrêts, pour reconnaître une ligne du fil parmi celles de la liste. */
    internal val keySet: Set<Any> by lazy { keys.toHashSet() }
}

/**
 * État du trait (`ThreadTrack`) : centre de chaque gouttière publié par `onLayoutRectChanged(0, 0)` (rappelé à chaque
 * image où la ligne bouge, avant le dessin de la même image, lot 0 de #115), lu en phase de dessin.
 */
@Stable
class ThreadTrackState internal constructor() {
    /** Centre vertical de la gouttière, repère racine, par clé de ligne. */
    internal val centers = mutableStateMapOf<Any, Float>()
    internal var listTop by mutableFloatStateOf(0f)
    internal var listHeight by mutableFloatStateOf(0f)

    /** La partie parcourue coule de [flowFrom] vers la perle suivante ([flowProgress] de 0 à 1). */
    internal var flowFrom = Float.NaN
    internal var flowProgress by mutableFloatStateOf(1f)

    /** Bouts tenus le temps du fondu d'une perle de bout qui part. */
    internal var heldTop by mutableStateOf<Float?>(null)
    internal var heldBottom by mutableStateOf<Float?>(null)

    /**
     * Repère du motif pointillé : un arrêt visible du fil ([dashKey]) et l'écart entre son centre et le début d'un
     * tiret ([dashDelta]). Reporté d'une image à l'autre pour que le motif défile sans sauter. Non observé.
     */
    internal var dashKey: Any? = null
    internal var dashDelta = 0f

    /** Dernier trait dessiné : point de départ d'un bout tenu ou d'une jonction qui coule. Non observé. */
    internal var drawn: ThreadTrackSegments? = null

    /** Le trait tel qu'il a été dessiné à la dernière image (px, repère de la liste) : tests de non-régression. */
    val lastDrawn: ThreadTrackSegments? get() = drawn
}

@Composable
fun rememberThreadTrackState(): ThreadTrackState = remember { ThreadTrackState() }

/** Trait de la liste en cours : les gouttières y publient la position de leur perle. */
val LocalThreadTrack = staticCompositionLocalOf<ThreadTrackState?> { null }

/** Mémoire de l'affectation précédente des marqueurs, pour reconnaître un départ ou une nouvelle perle suivante. */
private class MarkerMemo {
    var first: Any? = null
    var next: Any? = null
    var last: Any? = null
    var known = false

    /** Le marqueur [previous] a quitté le fil (et pas seulement changé de place). */
    fun departed(
        previous: Any?,
        path: ThreadPath,
    ): Boolean = known && previous != null && previous !in path.keys
}

/**
 * Dessine le fil une seule fois, derrière les lignes de la `LazyColumn` qu'il décore (option B de #115) : du premier
 * au dernier marqueur, à abscisse fixe, parcouru (accent) jusqu'à la perle suivante. Les lignes ne dessinent que leur
 * perle ou leur nœud (`ThreadGutter`), qui masque le trait dessous. À poser sur la `LazyColumn`, sous
 * `CompositionLocalProvider(LocalThreadTrack provides state)`.
 *
 * - Un bout hors écran s'arrête au bord ; la visibilité se lit dans `layoutInfo.visibleItemsInfo` (une ligne sortie de
 *   l'écran garde des coordonnées figées).
 * - Le trait couvre toujours toutes les perles visibles du fil : pendant un tri, une perle qui glisse au-delà du
 *   premier ou du dernier marqueur l'allonge d'autant.
 * - [animated] (liste qui glisse et fond ses lignes) : perle suivante qui change, la partie parcourue coule jusqu'à
 *   elle (`TicketMotion.check`) ; perle de bout qui part, le trait garde sa longueur le temps de son fondu
 *   (`TicketMotion.fade`). Sans animation (écran Liste) ou en mouvement réduit, le trait change dans la même image
 *   que les lignes.
 * - Pointillés (ordre générique ou en apprentissage) : motif calé sur le premier marqueur, puis reporté d'une image à
 *   l'autre, il défile avec le ticket sans sauter.
 */
@Composable
fun Modifier.threadTrack(
    state: ThreadTrackState,
    listState: LazyListState,
    path: ThreadPath,
    animated: Boolean = true,
): Modifier {
    val colors = Ticket.colors
    val highContrast = Ticket.accessibility.highContrast
    val look =
        TrackLook(
            passed = colors.thread,
            ahead = if (highContrast) colors.threadIdleHighContrast else colors.threadIdle,
            width = if (highContrast) TicketDimens.threadWidthHighContrast else TicketDimens.threadWidth,
            dashed = path.style == ThreadStyle.Dashed,
        )
    MarkerMotion(state, path, still = !animated || Ticket.accessibility.reducedMotion)
    return onLayoutRectChanged(throttleMillis = 0, debounceMillis = 0) { bounds ->
        state.listTop = bounds.positionInRoot.y.toFloat()
        state.listHeight = bounds.height.toFloat()
    }.drawBehind { drawThreadTrack(state, listState.layoutInfo, path, look) }
}

/** Couleurs, épaisseur et motif du trait. */
private class TrackLook(
    val passed: Color,
    val ahead: Color,
    val width: Dp,
    val dashed: Boolean,
)

/**
 * Mouvements des marqueurs : un bout dont la perle part est tenu le temps de son fondu ; la partie parcourue coule
 * vers une nouvelle perle suivante. L'affectation est comparée à la précédente pendant la composition, et l'effet posé
 * avant la mise en page et le dessin de la même image.
 */
@Composable
private fun MarkerMotion(
    state: ThreadTrackState,
    path: ThreadPath,
    still: Boolean,
) {
    val firstKey = path.keys.firstOrNull()
    val lastKey = path.keys.lastOrNull()
    val nextKey = path.nextKey
    val memo = remember { MarkerMemo() }
    val departedFirst = memo.departed(memo.first, path)
    val departedLast = memo.departed(memo.last, path)
    val nextMoved = memo.known && memo.next != nextKey
    SideEffect {
        val drawn = state.drawn
        if (still) {
            state.heldTop = null
            state.heldBottom = null
            state.flowProgress = 1f
        } else if (drawn != null) {
            if (departedFirst) state.heldTop = drawn.top
            if (departedLast) state.heldBottom = drawn.bottom
            if (nextMoved) {
                state.flowFrom = drawn.junction
                state.flowProgress = 0f
            }
        }
        memo.first = firstKey
        memo.next = nextKey
        memo.last = lastKey
        memo.known = true
    }
    LaunchedEffect(firstKey, lastKey) {
        if (state.heldTop != null || state.heldBottom != null) {
            delay(TicketMotion.FADE_MS.toLong())
            state.heldTop = null
            state.heldBottom = null
        }
    }
    LaunchedEffect(nextKey) {
        if (state.flowProgress < 1f) {
            animate(state.flowProgress, 1f, animationSpec = TicketMotion.check(still)) { value, _ ->
                state.flowProgress = value
            }
        }
    }
}

/** Centre du marqueur de l'arrêt [position] dans le repère de la liste, s'il est visible. */
private fun DrawScope.markerCenter(
    state: ThreadTrackState,
    info: LazyListLayoutInfo,
    path: ThreadPath,
    position: Int,
): Float? {
    val key = path.keys.getOrNull(position)
    return info.visibleItemsInfo.firstOrNull { key != null && it.key == key }?.let { itemCenter(state, it) }
}

/**
 * Centre de la perle d'une ligne visible, dans le repère de la liste. Les positions sont publiées en px racine : la
 * liste peut être mise à l'échelle par un parent (retour prédictif). Avant le premier rappel de la gouttière : centre
 * de la ligne, où la perle est centrée.
 */
private fun DrawScope.itemCenter(
    state: ThreadTrackState,
    item: LazyListItemInfo,
): Float {
    val scale = if (state.listHeight > 0f) size.height / state.listHeight else 1f
    return state.centers[item.key]?.let { (it - state.listTop) * scale } ?: (item.offset + item.size / 2f)
}

/** Place du marqueur de l'arrêt [position] : visible, au-dessus ou au-dessous de l'écran, ou absent. */
private fun DrawScope.markerPlace(
    state: ThreadTrackState,
    info: LazyListLayoutInfo,
    path: ThreadPath,
    position: Int,
): MarkerPlace {
    val firstVisible = info.visibleItemsInfo.firstOrNull()
    val center = markerCenter(state, info, path, position)
    return when {
        position !in path.keys.indices || firstVisible == null -> MarkerPlace.Absent
        center != null -> MarkerPlace.Visible(center)
        path.startIndex + position < firstVisible.index -> MarkerPlace.Above
        else -> MarkerPlace.Below
    }
}

/**
 * Le trait à dessiner, dans le repère de la liste : du premier au dernier marqueur, étiré pour couvrir toute perle
 * visible du fil (pendant un tri, celles qui glissent au-delà d'un bout) et les bouts tenus (perle de bout en fondu,
 * même s'il ne reste qu'un arrêt) ; la jonction coule vers la perle suivante. `null` : rien à dessiner.
 */
private fun DrawScope.trackSegments(
    state: ThreadTrackState,
    info: LazyListLayoutInfo,
    path: ThreadPath,
): ThreadTrackSegments? {
    fun place(position: Int) = markerPlace(state, info, path, position)
    val next = place(path.next)
    val base = threadTrackSegments(place(0), next, place(path.keys.lastIndex), size.height)
    val beads =
        info.visibleItemsInfo
            .filter { it.key in path.keySet }
            .map { itemCenter(state, it).coerceIn(0f, size.height) }
    val top = listOfNotNull(base?.top, beads.minOrNull(), state.heldTop).minOrNull()
    val bottom = listOfNotNull(base?.bottom, beads.maxOrNull(), state.heldBottom).maxOrNull()
    if (top == null || bottom == null || bottom <= top) return null
    val target =
        base?.junction ?: when (next) {
            is MarkerPlace.Visible -> next.y
            MarkerPlace.Above -> top
            MarkerPlace.Below, MarkerPlace.Absent -> bottom
        }
    val flowing = state.flowProgress < 1f && !state.flowFrom.isNaN()
    val flowed = if (flowing) state.flowFrom + (target - state.flowFrom) * state.flowProgress else target
    return ThreadTrackSegments(top, flowed.coerceIn(top, bottom), bottom)
}

private fun DrawScope.drawThreadTrack(
    state: ThreadTrackState,
    info: LazyListLayoutInfo,
    path: ThreadPath,
    look: TrackLook,
) {
    val segments = trackSegments(state, info, path)
    state.drawn = segments
    if (segments == null) return
    val (top, junction, bottom) = segments
    val center = ThreadLayout.start.toPx() + TicketDimens.threadGutter.toPx() / 2
    val x = if (layoutDirection == LayoutDirection.Ltr) center else size.width - center
    val stroke = look.width.toPx()
    drawLine(look.passed, Offset(x, top), Offset(x, junction), stroke)
    val pattern =
        if (look.dashed) {
            val period = stroke * 4
            val origin = dashOrigin(state, info, path, period) ?: top
            PathEffect.dashPathEffect(floatArrayOf(stroke * 2, stroke * 2), (junction - origin).mod(period))
        } else {
            null
        }
    drawLine(look.ahead, Offset(x, junction), Offset(x, bottom), stroke, pathEffect = pattern)
}

/**
 * Début d'un tiret du motif pointillé, dans le repère de la liste. Au départ, le premier marqueur s'il est visible.
 * Ensuite, le repère suit un arrêt visible du fil : quand il en change (celui du milieu de l'écran, pour ne jamais
 * dépendre d'une ligne qui sort), la phase est reportée par la distance entre l'ancien et le nouveau repère, tous deux
 * visibles à ce moment. Le motif défile ainsi avec le ticket, sans sauter au passage des lignes.
 */
private fun DrawScope.dashOrigin(
    state: ThreadTrackState,
    info: LazyListLayoutInfo,
    path: ThreadPath,
    period: Float,
): Float? {
    val stops = info.visibleItemsInfo.filter { it.key in path.keySet }
    if (stops.isEmpty()) {
        state.dashKey = null
        return null
    }
    val previous = stops.firstOrNull { it.key == state.dashKey }
    val origin =
        if (previous != null) {
            itemCenter(state, previous) + state.dashDelta
        } else {
            // Premier repère (ou ancien repère perdu d'un coup) : le premier marqueur, sinon le premier arrêt visible.
            markerCenter(state, info, path, 0) ?: itemCenter(state, stops.first())
        }
    val middle = stops.minBy { abs(itemCenter(state, it) - size.height / 2) }
    state.dashKey = middle.key
    // Ramené à une période : seule la phase compte.
    state.dashDelta = (origin - itemCenter(state, middle)).mod(period)
    return origin
}

// endregion
