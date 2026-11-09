package fr.parcourses.feature.shopping

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.ItemLine
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.ThreadPiece
import fr.parcourses.core.designsystem.ThreadStyle
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketCheckBox
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.thread
import kotlinx.coroutines.flow.distinctUntilChanged

/** Signale le début et la fin d'un balayage horizontal ; une ligne retirée en plein geste le termine. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeTracker(
    state: SwipeToDismissBoxState,
    onSwiping: (Boolean) -> Unit,
) {
    val current by rememberUpdatedState(onSwiping)
    var swiping by remember { mutableStateOf(false) }
    LaunchedEffect(state) {
        snapshotFlow { state.dismissDirection != SwipeToDismissBoxValue.Settled }
            .distinctUntilChanged()
            .collect {
                swiping = it
                current(it)
            }
    }
    DisposableEffect(state) { onDispose { if (swiping) current(false) } }
}

/**
 * Une ligne. Action par défaut : « Cocher » (ou « Décocher » si la ligne l'est déjà). Actions personnalisées pour
 * TalkBack : « Décocher » sur une ligne cochée, « Pas trouvé » sur une ligne à prendre ; le balayage n'est jamais la
 * seule voie. Le balayage : à droite coche, à gauche signale introuvable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ItemRow(
    row: ShoppingRow,
    look: RowLook,
    actions: ShoppingActions,
    modifier: Modifier = Modifier,
) {
    // L'état du balayage survit aux recompositions : sans cela, il agirait sur la ligne d'avant (cochée entre-temps).
    val current by rememberUpdatedState(row)
    val swipe =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                val latest = current
                when (value) {
                    SwipeToDismissBoxValue.StartToEnd -> {
                        if (!latest.isChecked) {
                            actions.onCheckFeedback()
                            actions.onToggle(latest)
                        }
                    }

                    SwipeToDismissBoxValue.EndToStart -> {
                        if (!latest.isChecked) actions.onNotFound(latest)
                    }

                    SwipeToDismissBoxValue.Settled -> {
                        Unit
                    }
                }
                // La ligne revient à sa place : c'est la liste qui change, pas le geste.
                false
            },
        )
    SwipeTracker(swipe, actions.onSwiping)
    SwipeToDismissBox(
        state = swipe,
        modifier = modifier,
        enableDismissFromStartToEnd = !row.isChecked,
        enableDismissFromEndToStart = !row.isChecked,
        backgroundContent = {},
    ) {
        ItemRowContent(row, look, actions)
    }
}

/** Apparence d'une ligne sur le fil : son morceau de fil, le style du fil, et si c'est l'article suivant. */
@Immutable
internal data class RowLook(
    val piece: ThreadPiece,
    val style: ThreadStyle,
    val isNext: Boolean = false,
    val highlighted: Boolean = false,
)

@Composable
internal fun ItemRowContent(
    row: ShoppingRow,
    look: RowLook,
    actions: ShoppingActions,
) {
    val colors = Ticket.colors
    val checkedText = stringResource(R.string.shopping_state_checked)
    val uncheckedText = stringResource(R.string.shopping_state_unchecked)
    val checkLabel = stringResource(R.string.shopping_action_check)
    val uncheckLabel = stringResource(R.string.shopping_action_uncheck)
    val notFoundLabel = stringResource(R.string.shopping_action_not_found)
    val custom =
        if (row.isChecked) {
            listOf(CustomAccessibilityAction(uncheckLabel) { actions.onToggle(row).let { true } })
        } else {
            listOf(CustomAccessibilityAction(notFoundLabel) { actions.onNotFound(row).let { true } })
        }
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .background(if (look.highlighted) colors.accent.copy(alpha = HIGHLIGHT_ALPHA) else colors.paper)
                .thread(look.piece, look.style)
                .heightIn(min = TicketDimens.rowMin)
                .clickable(onClickLabel = if (row.isChecked) uncheckLabel else checkLabel, role = Role.Checkbox) {
                    if (!row.isChecked) actions.onCheckFeedback()
                    actions.onToggle(row)
                }.semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    customActions = custom
                }.padding(start = ThreadLayout.contentStart, end = ThreadLayout.end, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // L'état se lit sans couleur : case pleine et cochée, texte barré.
        TicketCheckBox(row.isChecked)
        ItemLine(
            name = row.label,
            quantity = row.quantity,
            style = if (look.isNext) TicketType.itemNext else TicketType.item,
            color = if (row.isChecked) colors.checked else colors.ink,
            decoration = if (row.isChecked) TextDecoration.LineThrough else null,
            modifier = Modifier.weight(1f).padding(start = TicketDimens.spaceS),
        )
    }
}

@Composable
internal fun NotFoundRow(
    row: ShoppingRow,
    onRestore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val state = stringResource(R.string.shopping_state_not_found)
    val hint = stringResource(R.string.shopping_restore_hint)
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.touchMin)
                .clickable(onClickLabel = hint, role = Role.Button, onClick = onRestore)
                .semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = state
                }.padding(start = ThreadLayout.contentStart, end = ThreadLayout.end, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Introuvable : un « ? » à la place de la case, pour ne pas le dire par la seule couleur.
        Text(
            "?",
            style = TicketType.item,
            color = colors.inkMuted,
            modifier = Modifier.padding(horizontal = 9.dp).clearAndSetSemantics { },
        )
        ItemLine(
            name = row.label,
            quantity = null,
            style = TicketType.item,
            color = colors.inkMuted,
            modifier = Modifier.weight(1f).padding(start = TicketDimens.spaceS).clearAndSetSemantics { },
        )
        Text(
            stringResource(R.string.shopping_restore),
            style = MaterialTheme.typography.labelLarge,
            color = colors.accent,
            modifier = Modifier.clearAndSetSemantics { },
        )
    }
}

private const val HIGHLIGHT_ALPHA = 0.12f
