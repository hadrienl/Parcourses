package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.repository.ListSummary
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.RoleCapabilities
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.designsystem.MemberStack
import fr.parcourses.core.designsystem.SharingBadge
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

// « Mes listes », partie partage (#87, lot 87.6) : badges, initiales, menu d'une liste, confirmations.

/** Invitations en tête de « Mes listes ». */
@Composable
internal fun InvitationsEntry(invitations: ListsInvitationsUi) =
    InvitationsEntry(invitations.state, invitations.onAccept, invitations.onDecline, invitations.onOpenAll)

/** Supprimer une liste partagée : la confirmation nomme les membres qui la perdront. */
@Composable
internal fun SharedDeleteDialog(
    list: ListSummary,
    onClose: () -> Unit,
    onDelete: (String) -> Unit,
) {
    val names = list.sharedWith.map { memberName(it) }
    ConfirmDialog(
        title = stringResource(R.string.delete_shared_title, list.name),
        body = pluralStringResource(R.plurals.delete_shared_body, names.size, sharedNames(names)),
        confirm = stringResource(R.string.delete_shared_btn),
        dismiss = stringResource(R.string.common_cancel),
        onConfirm = {
            onClose()
            onDelete(list.id)
        },
        onDismiss = onClose,
    )
}

/** « Quitter la liste » : la liste disparaîtra de mes appareils. */
@Composable
internal fun LeaveListDialog(
    list: ListSummary,
    onClose: () -> Unit,
    onLeave: (String) -> Unit,
) {
    ConfirmDialog(
        title = stringResource(R.string.leave_title, list.name),
        body = stringResource(R.string.leave_body, ownerName(list.sharedWith.firstOrNull())),
        confirm = stringResource(R.string.leave_btn),
        dismiss = stringResource(R.string.common_cancel),
        onConfirm = {
            onClose()
            onLeave(list.id)
        },
        onDismiss = onClose,
    )
}

/** Menu ⋮ d'une liste : ce que mon rôle permet (renommer, supprimer, ou quitter). */
@Composable
internal fun ListRowMenu(
    expanded: Boolean,
    capabilities: RoleCapabilities,
    onDismiss: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onLeave: () -> Unit,
) {
    val close = onDismiss
    DropdownMenu(expanded = expanded, onDismissRequest = close) {
        if (capabilities.canRenameList) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.lists_rename)) },
                onClick = {
                    close()
                    onRename()
                },
            )
        }
        if (capabilities.canDeleteList) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.lists_delete)) },
                onClick = {
                    close()
                    onDelete()
                },
            )
        }
        if (capabilities.canLeave) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.lists_leave), color = Ticket.colors.destructive) },
                onClick = {
                    close()
                    onLeave()
                },
                modifier = Modifier.testTag(TAG_LEAVE_LIST),
            )
        }
    }
}

/** « Léa et Tom », « Léa, Tom et 2 autres » au-delà de trois prénoms. */
@Composable
internal fun sharedNames(names: List<String>): String =
    if (names.size > MAX_NAMED) {
        pluralStringResource(
            R.plurals.sharing_and_others,
            names.size - 2,
            names.take(2).joinToString(", "),
            names.size - 2,
        )
    } else {
        joinedNames(names)
    }

private const val MAX_NAMED = 3

/** Badge « PARTAGÉE » ou « LECTURE SEULE », puis les initiales des autres membres (décoratifs : voir [rowLabel]). */
@Composable
internal fun SharingRowBadges(list: ListSummary) {
    Row(
        Modifier.padding(top = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        val readOnly = list.role == ListRole.Viewer
        SharingBadge(
            stringResource(if (readOnly) R.string.ro_badge else R.string.lists_badge_shared),
            readOnly = readOnly,
        )
        MemberStack(avatarLabelsOf(list.sharedWith))
    }
}

/** « Courses de la semaine, partagée avec Léa et Tom, 7 articles restants » ; `null` pour une liste à soi seul. */
@Composable
internal fun rowLabel(
    list: ListSummary,
    subtitle: String,
): String? {
    if (!list.isShared) return null
    val names = joinedNames(list.sharedWith.map { memberName(it) })
    return if (list.role == ListRole.Viewer) {
        stringResource(R.string.lists_row_readonly_a11y, list.name, ownerName(list.sharedWith.firstOrNull()), subtitle)
    } else {
        stringResource(R.string.lists_row_shared_a11y, list.name, names, subtitle)
    }
}

/**
 * Liste retirée vue de « Mes listes » (maquette `removedlists`) : la ligne a disparu, « … n'est plus partagée avec
 * vous » reste [REMOVED_MESSAGE], puis le message est acquitté. Rend l'hôte du message, pour le `Scaffold`.
 */
@Composable
internal fun removedListMessage(
    notice: AccessChange.Removed?,
    onShown: (AccessChange.Removed) -> Unit,
): SnackbarHostState {
    val host = remember { SnackbarHostState() }
    val text = notice?.let { stringResource(R.string.sharing_removed_title, it.listName) }
    LaunchedEffect(notice) {
        if (notice == null || text == null) return@LaunchedEffect
        val shown = launch { host.showSnackbar(text, duration = SnackbarDuration.Indefinite) }
        delay(REMOVED_MESSAGE)
        shown.cancel()
        onShown(notice)
    }
    return host
}

/** Durée du message d'une liste retirée, vu de « Mes listes » (maquette : 4 s). */
internal val REMOVED_MESSAGE = 4.seconds
