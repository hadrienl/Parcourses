package fr.parcourses.core.designsystem

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

// region Mise en page

/** Au-delà de cette échelle de police (150 %), le ticket s'empile : compteur au-dessus, docks sur deux lignes. */
const val LARGE_TEXT_SCALE = 1.5f

/** Texte très agrandi : les pointillés disparaissent, les blocs côte à côte s'empilent (`typography.$note`). */
@Composable
fun isLargeText(): Boolean = LocalDensity.current.fontScale >= LARGE_TEXT_SCALE

/** Retrait du contenu d'une ligne filée : marge, gouttière du fil, puis un petit écart. */
object ThreadLayout {
    val start = 4.dp
    val contentStart = start + TicketDimens.threadGutter + TicketDimens.spaceXs
    val end = TicketDimens.spaceM
}

/** Le ticket : une feuille de papier posée sur le bureau, coins hauts arrondis. */
@Composable
fun TicketSheet(
    modifier: Modifier = Modifier,
    content: @Composable BoxScope.() -> Unit,
) {
    Box(
        modifier
            .fillMaxSize()
            .padding(horizontal = TicketDimens.ticketMargin)
            .clip(RoundedCornerShape(topStart = TicketDimens.radius, topEnd = TicketDimens.radius))
            .background(Ticket.colors.paper),
        content = content,
    )
}

/**
 * Texte affiché en capitales (titres du ticket, rayons) mais lu dans sa casse d'origine : TalkBack épellerait un mot
 * court en capitales (« BIO »). [heading] : lu comme un titre. Les propriétés posées par [modifier] (zone vive,
 * action) restent sur le même nœud.
 */
@Composable
fun CapsText(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    textAlign: TextAlign? = null,
    heading: Boolean = false,
) {
    Box(
        modifier.clearAndSetSemantics {
            this.text = AnnotatedString(text)
            if (heading) heading()
        },
    ) {
        Text(text.uppercase(), style = style, color = color, textAlign = textAlign)
    }
}

/** Filet pointillé sous l'en-tête du ticket. Décoratif. */
@Composable
fun DashedRule(modifier: Modifier = Modifier) {
    val color = Ticket.colors.inkMuted
    Canvas(modifier.fillMaxWidth().height(2.dp)) {
        val dash = 6.dp.toPx()
        drawLine(
            color = color,
            start = Offset(0f, size.height / 2),
            end = Offset(size.width, size.height / 2),
            strokeWidth = size.height,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash, dash / 2)),
        )
    }
}

/**
 * En-tête du ticket : titre en capitales (aucun si la barre du haut le porte déjà), lignes de méta, filet pointillé,
 * puis le compteur (« RESTE 05 »). En texte très agrandi, le compteur passe au-dessus de son libellé. Les textes
 * affichés sont décoratifs pour TalkBack : l'appelant fusionne l'en-tête et lui donne sa description (les capitales
 * seraient épelées).
 */
@Composable
fun TicketHeader(
    title: String?,
    meta: List<String>,
    totalLabel: String,
    total: Int,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    Column(
        modifier.fillMaxWidth().padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceM),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        title?.let { Text(it.uppercase(), style = TicketType.title, color = colors.ink, textAlign = TextAlign.Center) }
        meta.forEach { Text(it, style = TicketType.meta, color = colors.inkMuted, textAlign = TextAlign.Center) }
        if (title != null || meta.isNotEmpty()) DashedRule(Modifier.padding(top = TicketDimens.spaceXs, bottom = 4.dp))
        val count = total.coerceAtLeast(0).toString().padStart(2, '0')
        if (isLargeText()) {
            Column(Modifier.fillMaxWidth()) {
                Text(count, style = TicketType.total, color = colors.ink)
                Text(totalLabel.uppercase(), style = TicketType.aisle, color = colors.inkMuted)
            }
        } else {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                Text(
                    totalLabel.uppercase(),
                    style = TicketType.aisle,
                    color = colors.inkMuted,
                    modifier = Modifier.weight(1f).padding(bottom = TicketDimens.spaceXs),
                )
                Text(count, style = TicketType.total, color = colors.ink)
            }
        }
    }
}

// endregion

// region Barre basse

/**
 * Barre flottante en bas de l'écran (Material 3 Expressive : barre d'outils flottante et bouton d'action) : opaque,
 * au bord du papier, à portée du pouce.
 */
@Composable
fun DockPill(
    modifier: Modifier = Modifier,
    content: @Composable RowScope.() -> Unit,
) {
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(TicketDimens.primaryAction / 2),
        color = Ticket.colors.paperEdge,
        contentColor = Ticket.colors.ink,
        shadowElevation = 3.dp,
    ) {
        Row(
            Modifier.heightIn(min = TicketDimens.primaryAction).padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

/** Champ posé dans la barre flottante : ni fond ni trait propres, la barre en tient lieu. */
@Composable
fun dockFieldColors() =
    TextFieldDefaults.colors(
        focusedContainerColor = Color.Transparent,
        unfocusedContainerColor = Color.Transparent,
        disabledContainerColor = Color.Transparent,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
        disabledIndicatorColor = Color.Transparent,
    )

/**
 * Texte saisi dans la barre flottante : police du système, plus étroite que la mono, comme les commandes de la
 * maquette Android ; le libellé tient sur une ligne à côté du bouton d'action.
 */
@Composable
fun dockFieldTextStyle(): TextStyle = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Default)

// endregion
