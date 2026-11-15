package fr.parcourses.core.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Partage d'une liste (#87, maquettes `design/sharing-v1.html`, §0) : avatars d'initiale, pastilles empilées, badges.

/** Tailles des avatars : barre et lignes de liste, listes de membres, marque d'auteur. */
object AvatarSize {
    val stack = 28.dp
    val member = 36.dp
    val mark = 20.dp
}

/**
 * Avatar d'initiale : lettre mono 700 sur `paperEdge`, anneau couleur papier pour séparer les pastilles empilées. Pas
 * de couleur par membre. [outlined] : marque d'auteur, au trait `inkMuted`. Décoratif : l'appelant porte le libellé.
 */
@Composable
fun MemberAvatar(
    label: String,
    modifier: Modifier = Modifier,
    size: Dp = AvatarSize.stack,
    outlined: Boolean = false,
) {
    val colors = Ticket.colors
    val ring = if (outlined) colors.inkMuted else colors.paper
    Box(
        modifier
            .size(size)
            .clearAndSetSemantics { }
            .then(if (outlined) Modifier else Modifier.background(colors.paperEdge, CircleShape))
            .border(if (outlined) 1.dp else 2.dp, ring, CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style =
                TextStyle(
                    fontFamily = MonoFamily,
                    fontWeight = FontWeight.Bold,
                    // Taille fixe : l'avatar est décoratif et garde sa forme, le libellé lu suit la police du système.
                    fontSize = (size.value * AVATAR_TEXT_RATIO).sp,
                    textAlign = TextAlign.Center,
                ),
            color = if (outlined) colors.inkMuted else colors.ink,
            maxLines = 1,
            softWrap = false,
        )
    }
}

/**
 * Pastilles des autres membres (jamais moi), au plus [max] puis « +N ». En texte très agrandi, une seule pastille
 * portant le nombre de personnes.
 */
@Composable
fun MemberStack(
    labels: List<String>,
    modifier: Modifier = Modifier,
    max: Int = MAX_STACK,
) {
    if (labels.isEmpty()) return
    if (isLargeText()) {
        MemberAvatar((labels.size + 1).toString(), modifier)
        return
    }
    val shown = if (labels.size > max) labels.take(max - 1) + "+${labels.size - max + 1}" else labels
    Row(modifier, horizontalArrangement = Arrangement.spacedBy((-STACK_OVERLAP).dp)) {
        // L'ordre de composition empile de gauche à droite ; l'anneau papier sépare les pastilles.
        shown.forEach { label -> MemberAvatar(label) }
    }
}

/**
 * Libellés des pastilles : l'initiale de chacun ([initial]), deux lettres quand deux personnes ont la même (« Lé »,
 * « La »).
 */
fun avatarLabels(
    names: List<String?>,
    initial: (String?) -> String,
): List<String> {
    val initials = names.map(initial)
    return names.mapIndexed { index, name ->
        val clash = initials.count { it == initials[index] } > 1 && initials[index] != "?"
        val trimmed = name.orEmpty().trim()
        if (clash && trimmed.codePointCount(0, trimmed.length) > 1) {
            val second = trimmed.offsetByCodePoints(0, 1)
            val end = trimmed.offsetByCodePoints(second, 1)
            initials[index] + trimmed.substring(second, end).lowercase()
        } else {
            initials[index]
        }
    }
}

/** Badge mono majuscule : « PARTAGÉE » (accent, au trait) ou « LECTURE SEULE » (encre sur `paperEdge`). */
@Composable
fun SharingBadge(
    text: String,
    readOnly: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val shape = RoundedCornerShape(BADGE_RADIUS)
    val base =
        if (readOnly) {
            modifier.background(colors.paperEdge, shape)
        } else {
            modifier.border(1.dp, colors.accent, shape)
        }
    Text(
        text.uppercase(),
        style = TicketType.meta.copy(fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 1.sp),
        color = if (readOnly) colors.ink else colors.accent,
        modifier = base.padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/** Carte d'avertissement (`caution` sur `cautionFill`) ou d'information (papier bordé). */
@Composable
fun NoticeCard(
    modifier: Modifier = Modifier,
    caution: Boolean = true,
    content: @Composable () -> Unit,
) {
    val colors = Ticket.colors
    val fill: Color = if (caution) colors.cautionFill else colors.paperEdge
    val edge: Color = if (caution) colors.caution else colors.paperEdge
    Box(
        modifier
            .heightIn(min = TicketDimens.touchMin)
            .sizeIn(minWidth = TicketDimens.touchMin)
            .background(fill, RoundedCornerShape(TicketDimens.radius + 4.dp))
            .border(1.dp, edge, RoundedCornerShape(TicketDimens.radius + 4.dp))
            .padding(TicketDimens.spaceS),
    ) { content() }
}

private const val AVATAR_TEXT_RATIO = 0.46f
private const val STACK_OVERLAP = 6
private const val MAX_STACK = 3
private val BADGE_RADIUS = 4.dp
