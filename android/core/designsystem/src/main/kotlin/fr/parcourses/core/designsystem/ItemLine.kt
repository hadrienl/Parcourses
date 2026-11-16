package fr.parcourses.core.designsystem

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDecoration
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
 * Nom et quantité d'un article (#110) : le nom prend toute la largeur (sur plusieurs lignes s'il le faut), la quantité
 * passe dessous, en plus petit et en `inkMuted`. Une seule mise en page, quelle que soit la taille du texte.
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
    Column(modifier) {
        Text(name, style = style, color = color, textDecoration = decoration)
        if (quantity != null) Text(quantity, style = TicketType.quantity, color = Ticket.colors.inkMuted)
    }
}

/**
 * Échelle d'une ligne pendant un appui (#110) : elle s'enfonce légèrement tant que le doigt reste posé, annonce de
 * l'appui long. Aucune en mouvement réduit.
 */
@Composable
fun pressScale(interaction: InteractionSource): State<Float> {
    val pressed by interaction.collectIsPressedAsState()
    val reduced = Ticket.accessibility.reducedMotion
    return animateFloatAsState(
        if (pressed && !reduced) PRESSED_SCALE else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow),
        label = "press",
    )
}

// endregion

/** Échelle d'une ligne enfoncée. */
private const val PRESSED_SCALE = 0.97f

/** Coche dans la case, en fractions de son côté : départ, creux, pointe. */
private val CHECK_MARK = floatArrayOf(0.27f, 0.52f, 0.44f, 0.69f, 0.74f, 0.34f)
