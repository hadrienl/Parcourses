package fr.parcourses.core.designsystem

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp

// region Lignes d'article

/**
 * Case du ticket : carré cerclé d'encre, plein et coché quand l'article est pris. L'état se lit à la forme, pas à la
 * couleur. Décorative : la ligne porte l'état pour TalkBack.
 */
@Composable
fun TicketCheckBox(
    checked: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val fill by animateFloatAsState(
        if (checked) 1f else 0f,
        animationSpec = TicketMotion.check(Ticket.accessibility.reducedMotion),
        label = "check",
    )
    Canvas(modifier.size(TicketDimens.checkBox).clearAndSetSemantics { }) {
        val border = 2.dp.toPx()
        val corner = CornerRadius(4.dp.toPx())
        drawRoundRect(colors.ink.copy(alpha = fill), cornerRadius = corner)
        drawRoundRect(
            colors.ink,
            topLeft = Offset(border / 2, border / 2),
            size = size.copy(width = size.width - border, height = size.height - border),
            cornerRadius = corner,
            style = Stroke(border),
        )
        if (fill > 0f) {
            val mark =
                Path().apply {
                    moveTo(size.width * CHECK_MARK[0], size.height * CHECK_MARK[1])
                    lineTo(size.width * CHECK_MARK[2], size.height * CHECK_MARK[3])
                    lineTo(size.width * CHECK_MARK[4], size.height * CHECK_MARK[5])
                }
            drawPath(
                mark,
                colors.paper.copy(alpha = fill),
                style = Stroke(2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
            )
        }
    }
}

/**
 * Nom, pointillés, quantité : la ligne d'un ticket de caisse. Le nom prend la place dont il a besoin (sur plusieurs
 * lignes s'il le faut), la quantité garde la sienne ; les pointillés comblent l'écart. En texte très agrandi, les
 * pointillés disparaissent et la quantité passe sous le nom.
 */
@Composable
fun ItemLine(
    name: String,
    quantity: String?,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    decoration: TextDecoration? = null,
) {
    val colors = Ticket.colors
    if (isLargeText()) return StackedItemLine(name, quantity, style, color, modifier, decoration)
    val leader = quantity != null
    val gap = TicketDimens.spaceXs
    Layout(
        modifier = modifier,
        content = {
            Text(name, style = style, color = color, textDecoration = decoration)
            if (leader) {
                Canvas(Modifier.height(style.fontSize.value.dp)) {
                    val dot = 1.dp.toPx()
                    val y = size.height * LEADER_BASELINE
                    drawLine(
                        colors.inkMuted,
                        Offset(0f, y),
                        Offset(size.width, y),
                        strokeWidth = dot,
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(dot, dot * 2)),
                    )
                }
            }
            if (quantity != null) Text(quantity, style = TicketType.quantity, color = colors.inkMuted)
        },
    ) { measurables, constraints ->
        val gapPx = gap.roundToPx()
        val loose = constraints.copy(minWidth = 0, minHeight = 0)
        val quantityPlaceable = if (quantity != null) measurables.last().measure(loose) else null
        val quantityWidth = quantityPlaceable?.let { it.width + gapPx } ?: 0
        val minLeader = if (leader) gapPx * 2 else 0
        val nameMax = (constraints.maxWidth - quantityWidth - minLeader).coerceAtLeast(0)
        val namePlaceable = measurables[0].measure(loose.copy(maxWidth = nameMax))
        val leaderWidth = (constraints.maxWidth - namePlaceable.width - quantityWidth - gapPx).coerceAtLeast(0)
        val leaderPlaceable =
            if (leader) {
                measurables[1].measure(
                    Constraints.fixedWidth(leaderWidth).copy(maxHeight = loose.maxHeight),
                )
            } else {
                null
            }
        val height = maxOf(namePlaceable.height, quantityPlaceable?.height ?: 0)
        layout(constraints.maxWidth, height) {
            namePlaceable.placeRelative(0, (height - namePlaceable.height) / 2)
            leaderPlaceable?.placeRelative(
                namePlaceable.width + gapPx,
                (height - leaderPlaceable.height) / 2,
            )
            quantityPlaceable?.placeRelative(
                constraints.maxWidth - quantityPlaceable.width,
                (height - quantityPlaceable.height) / 2,
            )
        }
    }
}

// endregion

/** Coche dans la case, en fractions de son côté : départ, creux, pointe. */
private val CHECK_MARK = floatArrayOf(0.27f, 0.52f, 0.44f, 0.69f, 0.74f, 0.34f)

/** Hauteur des pointillés, près de la ligne de base du nom. */
private const val LEADER_BASELINE = 0.7f

/** Texte très agrandi : la quantité passe sous le nom, qui garde toute la largeur. */
@Composable
private fun StackedItemLine(
    name: String,
    quantity: String?,
    style: TextStyle,
    color: Color,
    modifier: Modifier,
    decoration: TextDecoration?,
) {
    Column(modifier) {
        Text(name, style = style, color = color, textDecoration = decoration)
        if (quantity != null) Text(quantity, style = TicketType.quantity, color = Ticket.colors.inkMuted)
    }
}
