package fr.parcourses.feature.shopping

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import fr.parcourses.core.designsystem.AisleLine
import fr.parcourses.core.designsystem.CapsText
import fr.parcourses.core.designsystem.LearnedTag
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.ThreadPiece
import fr.parcourses.core.designsystem.ThreadStyle
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketHeader
import fr.parcourses.core.designsystem.TicketType
import kotlinx.coroutines.delay

/**
 * En-tête du ticket (#6, B3) : magasin (ou liste) en titre, connaissance du trajet, puis « RESTE 05 ». Lu d'un bloc
 * comme un titre : « 5 à prendre, Carrefour, Trajet connu à 80 % » (ordre de lecture de #6 §5).
 */
@Composable
internal fun Header(state: ShoppingUiState) {
    val knowledge =
        when (val k = state.knowledge) {
            RouteKnowledge.NoStore -> stringResource(R.string.shopping_knowledge_no_store)
            RouteKnowledge.Unknown -> stringResource(R.string.shopping_knowledge_unknown)
            is RouteKnowledge.Learning -> stringResource(R.string.shopping_knowledge_learning, k.percent)
            is RouteKnowledge.Learned -> stringResource(R.string.shopping_knowledge_learned, k.percent)
        }
    val remaining = stringResource(R.string.shopping_remaining_header, state.toBuyCount)
    val description = listOfNotNull(remaining, state.storeName, knowledge).joinToString(", ")
    // Sans magasin, la barre du haut porte déjà le nom de la liste : pas de titre en double sur le ticket.
    TicketHeader(
        title = state.storeName,
        meta = listOf(knowledge),
        totalLabel = stringResource(R.string.shopping_total_label),
        total = state.toBuyCount,
        // L'étiquette de test avant `clearAndSetSemantics`, qui efface aussi ce qui la suit.
        modifier =
            Modifier.testTag(TAG_HEADER).clearAndSetSemantics {
                heading()
                contentDescription = description
            },
    )
}

/** Titre de rayon sur le fil : lu comme un en-tête, avec le nombre d'articles à prendre. */
@Composable
internal fun AisleHeader(
    section: ShoppingSection,
    piece: ThreadPiece,
    style: ThreadStyle,
    risen: Boolean,
    modifier: Modifier = Modifier,
) {
    val announcement = stringResource(R.string.shopping_aisle_count, section.title, section.remainingCount)
    AisleLine(
        categoryId = section.aisleId,
        title = section.title,
        piece = piece,
        style = style,
        modifier =
            modifier.clearAndSetSemantics {
                heading()
                contentDescription = announcement
            },
        trailing = { if (risen) LearnedTag() },
    )
}

@Composable
internal fun SectionTitle(title: String) {
    CapsText(
        title,
        style = TicketType.aisle,
        color = Ticket.colors.inkMuted,
        heading = true,
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(
                    start = ThreadLayout.contentStart,
                    end = ThreadLayout.end,
                    top = TicketDimens.spaceL,
                    bottom = TicketDimens.spaceXs,
                ),
    )
}

@Composable
internal fun BasketHeader(
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val title = stringResource(R.string.shopping_basket, count)
    val state =
        stringResource(if (expanded) R.string.shopping_basket_expanded else R.string.shopping_basket_collapsed)
    CapsText(
        title,
        style = TicketType.aisle,
        color = Ticket.colors.inkMuted,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.touchMin)
                .clickable(role = Role.Button, onClick = onToggle)
                .wrapContentHeight(Alignment.CenterVertically)
                .padding(start = ThreadLayout.contentStart, end = ThreadLayout.end, top = TicketDimens.spaceS)
                .testTag(TAG_BASKET)
                .semantics { stateDescription = state },
    )
}

/**
 * Suites de rayon qui viennent de remonter dans le trajet appris : celles dont un article passe devant un article
 * d'un autre rayon qu'il suivait. Les articles font foi, pas le rang des suites : une suite qui gagne une place parce
 * qu'une autre est finie, ou un rayon traversé deux fois dont la première suite disparaît, ne comptent pas, pas plus
 * qu'un article ajouté en route. [before] : identifiants des articles dans l'ordre affiché avant le tri.
 */
internal fun risenRuns(
    before: List<String>,
    after: List<ShoppingSection>,
): Set<String> {
    val old = before.withIndex().associate { it.value to it.index }
    val rows = after.flatMap { section -> section.rows.map { section to it.id } }.filter { it.second in old }
    return rows
        .withIndex()
        .filter { (index, entry) ->
            val (section, id) = entry
            rows.drop(index + 1).any { (other, otherId) ->
                other.aisleId != section.aisleId && old.getValue(otherId) < old.getValue(id)
            }
        }.map { it.value.first.id }
        .toSet()
}

/** Étiquette « ↑ appris » pendant [LEARNED_TAG_MS] sur les suites remontées, en mode appris seulement. */
@Composable
internal fun rememberRisenRuns(
    sections: List<ShoppingSection>,
    learned: Boolean,
): Set<String> {
    var previous by remember { mutableStateOf<List<String>?>(null) }
    var risen by remember { mutableStateOf(emptySet<String>()) }
    val order = sections.flatMap { section -> section.rows.map { it.id } }
    LaunchedEffect(order) {
        val before = previous
        previous = order
        risen = if (learned && before != null) risenRuns(before, sections) else emptySet()
        if (risen.isNotEmpty()) {
            delay(LEARNED_TAG_MS)
            risen = emptySet()
        }
    }
    return risen
}

internal const val LEARNED_TAG_MS = 3_000L
