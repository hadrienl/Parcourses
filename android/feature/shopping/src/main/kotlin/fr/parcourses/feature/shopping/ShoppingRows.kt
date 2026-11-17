package fr.parcourses.feature.shopping

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.AvatarSize
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.ItemLine
import fr.parcourses.core.designsystem.MemberAvatar
import fr.parcourses.core.designsystem.RowLane
import fr.parcourses.core.designsystem.ThreadBead
import fr.parcourses.core.designsystem.ThreadGutter
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketCheckBox
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.lanePress
import kotlinx.coroutines.flow.distinctUntilChanged
import fr.parcourses.core.designsystem.R as DesignR

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
 * TalkBack : « Décocher » sur une ligne cochée, « Pas trouvé » et « Modifier la quantité » sur une ligne à prendre ; le
 * balayage n'est jamais la seule voie. Le balayage : à droite coche, à gauche signale introuvable.
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
    ItemRowContent(row, look, actions, swipe, modifier)
}

/**
 * Apparence d'une ligne sur le fil : sa perle, sa clé `LazyColumn` si elle est un arrêt du fil (`null` au panier, hors
 * du fil), si c'est l'article suivant et s'il vient d'être ajouté.
 */
@Immutable
internal data class RowLook(
    val bead: Bead,
    val threadKey: Any?,
    val isNext: Boolean = false,
    val highlighted: Boolean = false,
)

/**
 * Contenu d'une ligne : la gouttière (perle) reste fixe, seul le couloir glisse (balayage), s'enfonce et ondule (#115).
 * Toute la ligne reste la cible de toucher. Appui long sur une ligne à prendre : menu « Pas trouvé », « Quantité »
 * (#110), avec vibration au déclenchement ; « Quantité » ouvre le panneau de l'article, que TalkBack offre aussi en
 * action « Modifier la quantité ».
 */
@OptIn(ExperimentalMaterial3Api::class)
@Suppress("LongMethod") // Une ligne : gestes, menu, sémantique TalkBack et contenu se lisent ensemble.
@Composable
internal fun ItemRowContent(
    row: ShoppingRow,
    look: RowLook,
    actions: ShoppingActions,
    swipe: SwipeToDismissBoxState,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val checkLabel = stringResource(R.string.shopping_action_check)
    val uncheckLabel = stringResource(R.string.shopping_action_uncheck)
    val state = rowStateDescription(row)
    val custom = rowAccessibilityActions(row, actions)
    var menuOpen by remember { mutableStateOf(false) }
    val interaction = remember { MutableInteractionSource() }
    Box(modifier) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .combinedClickable(
                        interactionSource = interaction,
                        // L'ondulation est dans le couloir (`lanePress`), jamais sur la gouttière.
                        indication = null,
                        onClickLabel = if (row.isChecked) uncheckLabel else checkLabel,
                        role = Role.Checkbox,
                        // Menu sur une ligne à prendre seulement : cochée, l'appui long ne fait rien.
                        onLongClick = if (row.isChecked) null else ({ menuOpen = true }),
                        hapticFeedbackEnabled = true,
                    ) {
                        if (!row.isChecked) actions.onCheckFeedback()
                        actions.onToggle(row)
                    }.semantics(mergeDescendants = true) {
                        contentDescription = row.accessibilityLabel
                        stateDescription = state
                        customActions = custom
                    }.padding(start = ThreadLayout.start),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ThreadGutter(look.threadKey) { ThreadBead(look.bead) }
            RowLane {
                SwipeToDismissBox(
                    state = swipe,
                    enableDismissFromStartToEnd = !row.isChecked,
                    enableDismissFromEndToStart = !row.isChecked,
                    backgroundContent = {},
                ) {
                    Row(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                // Article tout juste ajouté : surligné dans son couloir seulement (D3).
                                .then(
                                    if (look.highlighted) {
                                        Modifier.background(colors.accent.copy(alpha = HIGHLIGHT_ALPHA))
                                    } else {
                                        Modifier
                                    },
                                ).lanePress(interaction)
                                .heightIn(min = TicketDimens.rowMin)
                                .padding(
                                    start = TicketDimens.spaceXs,
                                    end = ThreadLayout.end,
                                    top = 6.dp,
                                    bottom = 6.dp,
                                ).testTag(TAG_ROW_LANE),
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
                        CheckedByMark(row.checkedBy)
                    }
                }
            }
        }
        RowMenu(
            expanded = menuOpen && !row.isChecked,
            onDismiss = { menuOpen = false },
            onNotFound = {
                menuOpen = false
                actions.onNotFound(row)
            },
            onQuantity = {
                menuOpen = false
                actions.onEditItem(row)
            },
        )
    }
}

/** Menu de l'appui long d'une ligne à prendre, en tête de la ligne. */
@Composable
private fun RowMenu(
    expanded: Boolean,
    onDismiss: () -> Unit,
    onNotFound: () -> Unit,
    onQuantity: () -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismiss,
        containerColor = Ticket.colors.paper,
        modifier = Modifier.testTag(TAG_ROW_MENU),
        offset = DpOffset(ThreadLayout.contentStart, 0.dp),
    ) {
        DropdownMenuItem(
            text = { Text(stringResource(R.string.shopping_action_not_found)) },
            onClick = onNotFound,
            modifier = Modifier.testTag(TAG_ROW_MENU_NOT_FOUND),
        )
        DropdownMenuItem(
            text = { Text(stringResource(R.string.shopping_menu_quantity)) },
            onClick = onQuantity,
            modifier = Modifier.testTag(TAG_ROW_MENU_QUANTITY),
        )
    }
}

/** État lu par TalkBack : « dans le panier, par Léa » si un autre membre l'a coché, sinon coché ou non coché. */
@Composable
private fun rowStateDescription(row: ShoppingRow): String =
    checkedByDescription(row)
        ?: stringResource(if (row.isChecked) R.string.shopping_state_checked else R.string.shopping_state_unchecked)

/**
 * Actions TalkBack d'une ligne, chacune là où elle a un sens : « Décocher » sur une ligne cochée ; « Pas trouvé » et
 * « Modifier la quantité » (#110) sur une ligne à prendre.
 */
@Composable
private fun rowAccessibilityActions(
    row: ShoppingRow,
    actions: ShoppingActions,
): List<CustomAccessibilityAction> {
    val uncheckLabel = stringResource(R.string.shopping_action_uncheck)
    val notFoundLabel = stringResource(R.string.shopping_action_not_found)
    val editLabel = stringResource(DesignR.string.item_edit_action)
    return if (row.isChecked) {
        listOf(CustomAccessibilityAction(uncheckLabel) { actions.onToggle(row).let { true } })
    } else {
        listOf(
            CustomAccessibilityAction(notFoundLabel) { actions.onNotFound(row).let { true } },
            CustomAccessibilityAction(editLabel) { actions.onEditItem(row).let { true } },
        )
    }
}

/** Coché par un autre membre : « dans le panier, par Léa » ; `null` sinon. */
@Composable
private fun checkedByDescription(row: ShoppingRow): String? =
    row.checkedBy?.let {
        stringResource(
            R.string.shopping_by_a11y,
            row.checkedByName?.takeIf(String::isNotBlank) ?: stringResource(R.string.shopping_someone),
        )
    }

/** Initiale de qui a coché, décorative : sa valeur passe dans l'état lu de la ligne. */
@Composable
private fun CheckedByMark(mark: String?) {
    if (mark == null) return
    MemberAvatar(
        mark,
        size = AvatarSize.mark,
        outlined = true,
        modifier = Modifier.padding(start = TicketDimens.spaceXs).testTag(TAG_CHECKED_BY),
    )
}

internal const val TAG_CHECKED_BY = "shopping-checked-by"
internal const val TAG_ROW_LANE = "shopping-row-lane"
internal const val TAG_ROW_MENU = "shopping-row-menu"
internal const val TAG_ROW_MENU_NOT_FOUND = "shopping-row-menu-not-found"
internal const val TAG_ROW_MENU_QUANTITY = "shopping-row-menu-quantity"

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
