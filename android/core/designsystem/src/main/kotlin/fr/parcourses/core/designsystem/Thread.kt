package fr.parcourses.core.designsystem

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onLayoutRectChanged
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp

// region Fil du parcours

/** Perle d'une ligne : pleine (cochée), anneau large (suivante), anneau fin (à venir). */
enum class Bead { None, Checked, Next, Idle }

/** Trajet appris : fil plein. Ordre générique ou en apprentissage : la partie à venir est pointillée (#6). */
enum class ThreadStyle { Solid, Dashed }

/**
 * Gouttière d'une ligne (`ThreadGutter`, #115) : colonne fixe au début de la ligne qui porte la perle ou le nœud. Elle
 * n'est jamais décalée, mise à l'échelle ni soulevée ; seul le couloir ([RowLane]) bouge. [threadKey] : clé
 * `LazyColumn` de la ligne si elle est un arrêt du fil ; la gouttière publie alors la hauteur de son marqueur
 * (`threadMarker`, son centre) vers le trait de la liste ([LocalThreadTrack]). Décorative.
 */
@Composable
fun ThreadGutter(
    threadKey: Any?,
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    val track = LocalThreadTrack.current
    val publish =
        if (track != null && threadKey != null) {
            DisposableEffect(track, threadKey) { onDispose { track.centers.remove(threadKey) } }
            // Sans rebond : la valeur doit arriver dans l'image même où la ligne bouge (lot 0 de #115).
            Modifier.onLayoutRectChanged(throttleMillis = 0, debounceMillis = 0) { bounds ->
                track.centers[threadKey] = bounds.positionInRoot.y + bounds.height / 2f
            }
        } else {
            Modifier
        }
    Box(
        modifier.size(TicketDimens.threadGutter).then(publish).clearAndSetSemantics { },
        contentAlignment = Alignment.Center,
        content = content,
    )
}

/** Perle d'une ligne, au centre de sa gouttière, sur fond papier : elle masque le trait dessous. */
@Composable
fun ThreadBead(
    bead: Bead,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val highContrast = Ticket.accessibility.highContrast
    val ring = if (highContrast) colors.ink else colors.threadIdle
    val width = if (highContrast) TicketDimens.threadWidthHighContrast else TicketDimens.threadWidth
    val reduced = Ticket.accessibility.reducedMotion
    val beadColor by animateColorAsState(
        when (bead) {
            Bead.Checked, Bead.Next -> colors.thread
            Bead.Idle, Bead.None -> ring
        },
        animationSpec = TicketMotion.check(reduced),
        label = "bead",
    )
    Spacer(modifier.fillMaxSize().drawBehind { drawBead(bead, center, beadColor, colors.paper, width.toPx()) })
}

/**
 * Couloir d'une ligne (`RowLane`, #115) : case, libellé, points de conduite, quantité, marque d'auteur. Seule partie
 * qui glisse, s'enfonce ou montre l'ondulation ; rogné à son bord, il passe sous la gouttière sans la recouvrir.
 */
@Composable
fun RowScope.RowLane(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(modifier.weight(1f).clipToBounds(), content = content)
}

/**
 * Retour d'appui du couloir : l'ondulation et l'enfoncement (0,97, depuis le bord de début) suivent [interaction],
 * celle de la ligne entière, qui reste la cible de toucher (48 dp au moins) ; la gouttière n'est jamais touchée.
 */
@Composable
fun Modifier.lanePress(interaction: InteractionSource): Modifier {
    val scale = pressScale(interaction)
    val origin = if (LocalLayoutDirection.current == LayoutDirection.Ltr) LANE_START_LTR else LANE_START_RTL
    return indication(interaction, ripple()).graphicsLayer {
        scaleX = scale.value
        scaleY = scale.value
        transformOrigin = origin
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
 * Ligne de titre de rayon sur le fil : nœud dans la gouttière ([threadKey] : clé `LazyColumn` de la ligne, arrêt du
 * fil), nom en capitales. [trailing] : étiquette éventuelle (« ↑ appris »). Pas de fond : le trait de la liste passe
 * dessous. La sémantique (titre, nombre d'articles) est posée par l'appelant.
 */
@Composable
fun AisleLine(
    categoryId: String,
    title: String,
    threadKey: Any?,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier
            .fillMaxWidth()
            .heightIn(min = TicketDimens.touchMin)
            .padding(start = ThreadLayout.start, end = ThreadLayout.end),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ThreadGutter(threadKey) { AisleNode(categoryId) }
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

/** Origine de l'enfoncement du couloir : son bord de début, à mi-hauteur. */
private val LANE_START_LTR = TransformOrigin(0f, 0.5f)
private val LANE_START_RTL = TransformOrigin(1f, 0.5f)
