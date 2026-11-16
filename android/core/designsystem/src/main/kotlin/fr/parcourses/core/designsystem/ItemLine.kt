package fr.parcourses.core.designsystem

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.AlignmentLine
import androidx.compose.ui.layout.FirstBaseline
import androidx.compose.ui.layout.LastBaseline
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.Placeable
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

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
 * Nom, pointillés, quantité : la ligne d'un ticket de caisse. Le nom et la quantité tiennent sur une ligne : les
 * pointillés comblent l'écart. Sinon (#110), seul le nom se replie ; la quantité reste une colonne à droite qui ne se
 * coupe jamais, alignée sur la dernière ligne du nom, et les pointillés relient la fin du texte à la quantité. Si cette
 * colonne dépasse [MAX_QUANTITY_SHARE] de la largeur (quantité très longue, texte très agrandi), la quantité passe sous
 * le nom. Même règle qu'iOS (`LeaderLineLayout`).
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
    val leader = quantity != null
    val gap = TicketDimens.spaceXs
    // Mise en page du nom, relevée pendant sa mesure : un nom replié fait partir les pointillés de sa dernière ligne.
    val nameLayout = remember { NameLayout() }
    Layout(
        modifier = modifier,
        content = {
            Text(
                name,
                style = style,
                color = color,
                textDecoration = decoration,
                onTextLayout = { nameLayout.result = it },
            )
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
        measureItemLine(measurables, constraints, gap.roundToPx(), leader, nameLayout)
    }
}

/** Dernière mise en page du nom (pas un état : lue pendant la même mesure, juste après celle du texte). */
private class NameLayout {
    var result: TextLayoutResult? = null
}

/** Mesure et place nom, pointillés et quantité : sur une ligne, nom replié, ou quantité dessous (voir [ItemLine]). */
private fun MeasureScope.measureItemLine(
    measurables: List<Measurable>,
    constraints: Constraints,
    gapPx: Int,
    leader: Boolean,
    nameLayout: NameLayout,
): MeasureResult {
    val loose = constraints.copy(minWidth = 0, minHeight = 0)
    val quantity = if (leader) measurables.last().measure(loose) else null
    val quantityWidth = quantity?.let { it.width + gapPx } ?: 0
    val nameMax = (constraints.maxWidth - quantityWidth - if (leader) gapPx * 2 else 0).coerceAtLeast(0)
    val fitsOnOneLine = measurables[0].maxIntrinsicWidth(Constraints.Infinity) <= nameMax
    return when {
        fitsOnOneLine -> {
            val leaderMeasurable = if (leader) measurables[1] else null
            val name = measurables[0].measure(loose.copy(maxWidth = nameMax))
            placeInline(name, leaderMeasurable, quantity, gapPx, loose)
        }

        quantity != null && quantityWidth <= constraints.maxWidth * MAX_QUANTITY_SHARE -> {
            // Même largeur qu'en ligne : la dernière ligne du nom garde la place d'un minimum de pointillés (un mot qui
            // ne la laisserait pas passe à la ligne), et un nom qui tiendrait sur une ligne relève du premier cas.
            val name = measurables[0].measure(loose.copy(maxWidth = nameMax))
            val leaderEnd = constraints.maxWidth - quantity.width - gapPx
            val lastLineLeader = measureLastLineLeader(measurables[1], nameLayout, gapPx, leaderEnd)
            placeWrapped(name, quantity, lastLineLeader, constraints.maxWidth)
        }

        else -> {
            placeStacked(measurables[0].measure(loose), quantity, constraints.maxWidth)
        }
    }
}

/** Tout sur une ligne : les pointillés comblent l'écart entre le nom et la quantité. */
private fun MeasureScope.placeInline(
    name: Placeable,
    leaderMeasurable: Measurable?,
    quantity: Placeable?,
    gapPx: Int,
    loose: Constraints,
): MeasureResult {
    val width = loose.maxWidth
    val quantityWidth = quantity?.let { it.width + gapPx } ?: 0
    val leaderWidth = (width - name.width - quantityWidth - gapPx).coerceAtLeast(0)
    val leader = leaderMeasurable?.measure(Constraints.fixedWidth(leaderWidth).copy(maxHeight = loose.maxHeight))
    val height = maxOf(name.height, quantity?.height ?: 0)
    return layout(width, height) {
        name.placeRelative(0, (height - name.height) / 2)
        leader?.placeRelative(name.width + gapPx, (height - leader.height) / 2)
        quantity?.placeRelative(width - quantity.width, (height - quantity.height) / 2)
    }
}

/** Pointillés mesurés et leur position (gauche, milieu vertical), en pixels. */
private class PlacedLeader(
    val placeable: Placeable,
    val x: Int,
    val middle: Int,
)

/**
 * Pointillés d'un nom replié : de la fin de sa dernière ligne (plus un écart) jusqu'à [end], centrés sur cette ligne.
 * `null` tant que la mise en page du nom n'est pas connue.
 */
private fun measureLastLineLeader(
    leader: Measurable,
    nameLayout: NameLayout,
    gapPx: Int,
    end: Int,
): PlacedLeader? {
    val layout = nameLayout.result ?: return null
    val last = layout.lineCount - 1
    val x = layout.getLineRight(last).roundToInt() + gapPx
    val placeable = leader.measure(Constraints.fixedWidth((end - x).coerceAtLeast(0)))
    return PlacedLeader(placeable, x, ((layout.getLineTop(last) + layout.getLineBottom(last)) / 2).roundToInt())
}

/**
 * Nom replié à gauche ; quantité en colonne à droite, alignée sur la ligne de base de la dernière ligne du nom, et
 * pointillés de la fin de cette ligne à la quantité.
 */
private fun MeasureScope.placeWrapped(
    name: Placeable,
    quantity: Placeable,
    leader: PlacedLeader?,
    width: Int,
): MeasureResult {
    val quantityY = lastBaselineOffset(name, quantity)
    val height = maxOf(name.height, quantityY + quantity.height)
    return layout(width, height) {
        name.placeRelative(0, 0)
        leader?.let { it.placeable.placeRelative(it.x, it.middle - it.placeable.height / 2) }
        quantity.placeRelative(width - quantity.width, quantityY)
    }
}

/** Quantité sous le nom, qui garde toute la largeur. */
private fun MeasureScope.placeStacked(
    name: Placeable,
    quantity: Placeable?,
    width: Int,
): MeasureResult {
    val height = name.height + (quantity?.height ?: 0)
    return layout(width, height) {
        name.placeRelative(0, 0)
        quantity?.placeRelative(0, name.height)
    }
}

/** Haut de la quantité qui aligne sa ligne de base sur la dernière ligne de base du nom. */
private fun lastBaselineOffset(
    name: Placeable,
    quantity: Placeable,
): Int {
    val nameBaseline = name[LastBaseline]
    val quantityBaseline = quantity[FirstBaseline]
    if (nameBaseline == AlignmentLine.Unspecified || quantityBaseline == AlignmentLine.Unspecified) return 0
    return (nameBaseline - quantityBaseline).coerceAtLeast(0)
}

// endregion

/** Coche dans la case, en fractions de son côté : départ, creux, pointe. */
private val CHECK_MARK = floatArrayOf(0.27f, 0.52f, 0.44f, 0.69f, 0.74f, 0.34f)

/** Hauteur des pointillés, près de la ligne de base du nom. */
private const val LEADER_BASELINE = 0.7f

/**
 * Part de la largeur que la quantité peut prendre à droite d'un nom replié (#110). Au-delà, le nom n'aurait plus que
 * quelques caractères par ligne : la quantité passe dessous.
 */
private const val MAX_QUANTITY_SHARE = 0.4f
