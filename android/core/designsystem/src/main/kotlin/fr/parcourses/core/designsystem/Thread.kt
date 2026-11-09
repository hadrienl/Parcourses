package fr.parcourses.core.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

// region Fil du parcours

/** Morceau du fil au-dessus ou au-dessous de la perle d'une ligne. */
enum class ThreadSegment {
    /** Pas de fil (début ou fin). */
    None,

    /** Déjà parcouru : accent. */
    Passed,

    /** Encore à parcourir. */
    Ahead,
}

/** Perle d'une ligne : pleine (cochée), anneau large (suivante), anneau fin (à venir). */
enum class Bead { None, Checked, Next, Idle }

/** Trajet appris : fil plein. Ordre générique ou en apprentissage : la partie à venir est pointillée (#6). */
enum class ThreadStyle { Solid, Dashed }

@Immutable
data class ThreadPiece(
    val top: ThreadSegment,
    val bottom: ThreadSegment,
    val bead: Bead = Bead.None,
)

/**
 * Dessine le fil dans la gouttière de début de ligne (à droite en écriture de droite à gauche) : un segment au-dessus,
 * un au-dessous, la perle au milieu. Purement décoratif : l'état se lit sur la ligne elle-même.
 */
@Composable
fun Modifier.thread(
    piece: ThreadPiece,
    style: ThreadStyle,
): Modifier {
    val colors = Ticket.colors
    val highContrast = Ticket.accessibility.highContrast
    val idle = if (highContrast) colors.threadIdleHighContrast else colors.threadIdle
    val ring = if (highContrast) colors.ink else colors.threadIdle
    val width = if (highContrast) TicketDimens.threadWidthHighContrast else TicketDimens.threadWidth
    val reduced = Ticket.accessibility.reducedMotion
    val beadColor by animateColorAsState(
        when (piece.bead) {
            Bead.Checked, Bead.Next -> colors.thread
            Bead.Idle, Bead.None -> ring
        },
        animationSpec = TicketMotion.check(reduced),
        label = "bead",
    )
    return drawBehind {
        val center = ThreadLayout.start.toPx() + TicketDimens.threadGutter.toPx() / 2
        val x = if (layoutDirection == LayoutDirection.Ltr) center else size.width - center
        val y = size.height / 2
        val stroke = width.toPx()
        val dashed = PathEffect.dashPathEffect(floatArrayOf(stroke * 2, stroke * 2))

        fun segment(
            kind: ThreadSegment,
            from: Float,
            to: Float,
        ) {
            if (kind == ThreadSegment.None) return
            val passed = kind == ThreadSegment.Passed
            drawLine(
                color = if (passed) colors.thread else idle,
                start = Offset(x, from),
                end = Offset(x, to),
                strokeWidth = stroke,
                pathEffect = if (!passed && style == ThreadStyle.Dashed) dashed else null,
            )
        }
        segment(piece.top, 0f, y)
        segment(piece.bottom, y, size.height)
        drawBead(piece.bead, Offset(x, y), beadColor, colors.paper, stroke)
    }
}

private fun DrawScope.drawBead(
    bead: Bead,
    center: Offset,
    color: Color,
    paper: Color,
    stroke: Float,
) {
    val diameter =
        when (bead) {
            Bead.None -> return
            Bead.Next -> TicketDimens.beadNext.toPx()
            Bead.Checked, Bead.Idle -> TicketDimens.bead.toPx()
        }
    val radius = diameter / 2
    if (bead == Bead.Checked) {
        drawCircle(color, radius, center)
    } else {
        drawCircle(paper, radius, center)
        drawCircle(color, radius - stroke / 2, center, style = Stroke(stroke))
    }
}

/**
 * Nœud de rayon sur le fil : icône au trait dans un anneau, aux couleurs du rayon. Décoratif : le nom du rayon est
 * toujours écrit à côté.
 */
@Composable
fun AisleNode(
    categoryId: String,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val color = colors.aisleColor(categoryId)
    Box(
        modifier
            .size(TicketDimens.aisleNode)
            .clip(CircleShape)
            .background(colors.paper)
            .border(1.5.dp, color, CircleShape)
            .clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(categoryIcon(categoryId)),
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(TicketDimens.aisleIcon),
        )
    }
}

/**
 * Ligne de titre de rayon sur le fil : nœud dans la gouttière, nom en capitales. [trailing] : étiquette éventuelle
 * (« ↑ appris »). La sémantique (titre, nombre d'articles) est posée par l'appelant.
 */
@Composable
fun AisleLine(
    categoryId: String,
    title: String,
    piece: ThreadPiece,
    style: ThreadStyle,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier
            .fillMaxWidth()
            .background(Ticket.colors.paper)
            .thread(piece, style)
            .heightIn(min = TicketDimens.touchMin)
            .padding(start = ThreadLayout.start, end = ThreadLayout.end),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(TicketDimens.threadGutter), contentAlignment = Alignment.Center) { AisleNode(categoryId) }
        CapsText(
            title,
            style = TicketType.aisle,
            color = Ticket.colors.inkMuted,
            modifier = Modifier.weight(1f).padding(start = TicketDimens.spaceXs, top = 4.dp, bottom = 4.dp),
        )
        trailing()
    }
}

/** Étiquette « ↑ appris » d'un rayon qui vient de remonter (`structure.learnedTagMs`). Décorative. */
@Composable
fun LearnedTag(modifier: Modifier = Modifier) {
    Text(
        stringResource(R.string.ticket_learned_tag),
        style = TicketType.aisle,
        color = Ticket.colors.accent,
        modifier = modifier.clearAndSetSemantics { },
    )
}

// endregion

/**
 * Fil d'une suite de [count] éléments (titres de rayon et lignes, dans l'ordre affiché) dont [next] est la position de
 * l'article suivant ([count] quand tout est pris) : parcouru jusqu'à la perle suivante, à venir ensuite.
 */
fun threadSegments(
    count: Int,
    next: Int,
): List<Pair<ThreadSegment, ThreadSegment>> =
    List(count) { i ->
        val top =
            when {
                i == 0 -> ThreadSegment.None
                i <= next -> ThreadSegment.Passed
                else -> ThreadSegment.Ahead
            }
        val bottom =
            when {
                i == count - 1 -> ThreadSegment.None
                i < next -> ThreadSegment.Passed
                else -> ThreadSegment.Ahead
            }
        top to bottom
    }
