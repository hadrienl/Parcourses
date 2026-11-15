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
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.designsystem.MemberStack
import fr.parcourses.core.designsystem.SharingBadge
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType

/** Écran Listes branché sur son [ListsViewModel]. */
@Composable
fun ListsRoute(
    viewModel: ListsViewModel,
    onOpen: (String) -> Unit,
    modifier: Modifier = Modifier,
    onAbout: (() -> Unit)? = null,
    aboutNeedsAttention: Boolean = false,
    account: ListsAccountUi = ListsAccountUi(),
    invitations: ListsInvitationsUi = ListsInvitationsUi(),
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    ListsScreen(
        state = state,
        onOpen = onOpen,
        onCreate = { name -> viewModel.create(name, onCreated = onOpen) },
        onRename = viewModel::rename,
        onDelete = viewModel::delete,
        onDismissError = viewModel::dismissError,
        modifier = modifier,
        onAbout = onAbout,
        aboutNeedsAttention = aboutNeedsAttention,
        account = account,
        invitations = invitations,
        onLeave = viewModel::leave,
    )
}

/** Invitations reçues, vues de « Mes listes » (#87, lot 87.6). */
@Immutable
data class ListsInvitationsUi(
    val state: InvitationsUiState = InvitationsUiState(),
    val onAccept: (fr.parcourses.core.network.dto.ReceivedInvitation) -> Unit = {},
    val onDecline: (fr.parcourses.core.network.dto.ReceivedInvitation) -> Unit = {},
    val onOpenAll: () -> Unit = {},
)

/** Dialogue ouvert sur l'écran Listes. */
private sealed interface ListDialog {
    data object Create : ListDialog

    data class Rename(
        val list: ListSummary,
    ) : ListDialog

    data class Delete(
        val list: ListSummary,
    ) : ListDialog

    /** « Quitter la liste » d'un membre (#87). */
    data class Leave(
        val list: ListSummary,
    ) : ListDialog
}

private val ListDialogSaver =
    Saver<ListDialog?, List<Any?>>(
        save = { dialog ->
            when (dialog) {
                null -> emptyList()
                ListDialog.Create -> listOf("create")
                is ListDialog.Rename -> listOf("rename") + dialog.list.toSaved()
                is ListDialog.Delete -> listOf("delete") + dialog.list.toSaved()
                is ListDialog.Leave -> listOf("leave") + dialog.list.toSaved()
            }
        },
        restore = { saved ->
            when (saved.firstOrNull()) {
                "create" -> ListDialog.Create
                "rename" -> ListDialog.Rename(saved.toList())
                "delete" -> ListDialog.Delete(saved.toList())
                "leave" -> ListDialog.Leave(saved.toList())
                else -> null
            }
        },
    )

private fun ListSummary.toSaved(): List<Any?> = listOf(id, name, remaining, total, role.wireName, ArrayList(sharedWith))

// Une liste sauvegardée : le type du dialogue, puis ses quatre champs.
private const val SAVED_ID = 1
private const val SAVED_NAME = 2
private const val SAVED_REMAINING = 3
private const val SAVED_TOTAL = 4
private const val SAVED_ROLE = 5
private const val SAVED_SHARED_WITH = 6

@Suppress("UNCHECKED_CAST") // écrit par `toSaved` juste au-dessus
private fun List<Any?>.toList(): ListSummary =
    ListSummary(
        this[SAVED_ID] as String,
        this[SAVED_NAME] as String,
        this[SAVED_REMAINING] as Int,
        this[SAVED_TOTAL] as Int,
        ListRole.fromWire(getOrNull(SAVED_ROLE) as? String) ?: ListRole.Owner,
        (getOrNull(SAVED_SHARED_WITH) as? List<String?>).orEmpty(),
    )

/**
 * Écran Listes : état vide, création, renommage, suppression. Sans état propre hors dialogues. [onAbout] ouvre
 * « À propos » (attribution des données et confidentialité).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListsScreen(
    state: ListsUiState,
    onOpen: (String) -> Unit,
    onCreate: (String) -> Unit,
    onRename: (id: String, name: String) -> Unit,
    onDelete: (String) -> Unit,
    onDismissError: () -> Unit,
    modifier: Modifier = Modifier,
    onAbout: (() -> Unit)? = null,
    aboutNeedsAttention: Boolean = false,
    account: ListsAccountUi = ListsAccountUi(),
    invitations: ListsInvitationsUi = ListsInvitationsUi(),
    onLeave: (String) -> Unit = {},
) {
    var dialog by rememberSaveable(stateSaver = ListDialogSaver) { mutableStateOf<ListDialog?>(null) }
    var confirmingAnonymous by rememberSaveable { mutableStateOf(false) }
    // Reprise de compte : la liste visée par un dialogue a changé d'identifiant ou disparu, il se ferme.
    LaunchedEffect(state.lists, state.isLoaded) {
        val target =
            when (val open = dialog) {
                is ListDialog.Rename -> open.list.id
                is ListDialog.Delete -> open.list.id
                is ListDialog.Leave -> open.list.id
                else -> null
            }
        if (state.isLoaded && target != null && state.lists.none { it.id == target }) dialog = null
    }
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = { ListsTopBar(onAbout, aboutNeedsAttention, account.onSignIn.takeIf { account.canSignIn }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { dialog = ListDialog.Create },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text(stringResource(R.string.lists_new)) },
                containerColor = colors.accent,
                contentColor = colors.onAccent,
                modifier = Modifier.testTag(TAG_NEW_LIST),
            )
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
            Column(Modifier.fillMaxSize()) {
                if (account.needsSignIn) {
                    SessionLostBanner(onReconnect = account.onSignIn, onAnonymous = { confirmingAnonymous = true })
                }
                ListsBody(
                    state,
                    onOpen,
                    onDialog = { dialog = it },
                    top = {
                        InvitationsEntry(
                            invitations.state,
                            invitations.onAccept,
                            invitations.onDecline,
                            invitations.onOpenAll,
                        )
                    },
                    bottom = { if (account.canSignIn) AnonymousInvitationHint(account.onSignIn) },
                )
            }
        }
    }
    if (confirmingAnonymous && account.needsSignIn) {
        ContinueWithoutAccountDialog(
            unsentChanges = account.unsentChanges,
            onConfirm = {
                confirmingAnonymous = false
                account.onContinueWithoutAccount()
            },
            onDismiss = { confirmingAnonymous = false },
        )
    }
    ListDialogs(
        dialog = dialog,
        onClose = { dialog = null },
        onCreate = onCreate,
        onRename = onRename,
        onDelete = onDelete,
        onLeave = onLeave,
    )
    state.errorDetail?.let { ErrorDialog(it, onDismissError) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ListsTopBar(
    onAbout: (() -> Unit)?,
    needsAttention: Boolean,
    onSignIn: (() -> Unit)?,
) {
    TopAppBar(
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Ticket.colors.desk),
        title = { Text(stringResource(R.string.lists_title)) },
        actions = {
            if (onSignIn != null) {
                TextButton(
                    onClick = onSignIn,
                    modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_SIGN_IN),
                ) { Text(stringResource(R.string.lists_sign_in), color = Ticket.colors.accent) }
            }
            if (onAbout != null) {
                IconButton(onClick = onAbout, modifier = Modifier.testTag(TAG_ABOUT)) {
                    // Pastille : À propos propose une action (session illisible, #51).
                    val label =
                        stringResource(if (needsAttention) R.string.lists_about_attention else R.string.lists_about)
                    BadgedBox(badge = { if (needsAttention) Badge(Modifier.testTag(TAG_ABOUT_BADGE)) }) {
                        Icon(Icons.Outlined.Info, contentDescription = label)
                    }
                }
            }
        },
    )
}

@Composable
private fun ListDialogs(
    dialog: ListDialog?,
    onClose: () -> Unit,
    onCreate: (String) -> Unit,
    onRename: (id: String, name: String) -> Unit,
    onDelete: (String) -> Unit,
    onLeave: (String) -> Unit,
) {
    when (val current = dialog) {
        ListDialog.Create -> {
            NameDialog(
                title = stringResource(R.string.lists_new),
                confirmLabel = stringResource(R.string.lists_create),
                initialName = "",
                onConfirm = {
                    onClose()
                    onCreate(it)
                },
                onDismiss = { onClose() },
            )
        }

        is ListDialog.Rename -> {
            NameDialog(
                title = stringResource(R.string.lists_rename_title),
                confirmLabel = stringResource(R.string.lists_rename),
                initialName = current.list.name,
                onConfirm = {
                    onClose()
                    onRename(current.list.id, it)
                },
                onDismiss = { onClose() },
            )
        }

        is ListDialog.Delete -> {
            if (current.list.isShared) {
                val names = current.list.sharedWith.map { memberName(it) }
                ConfirmDialog(
                    title = stringResource(R.string.delete_shared_title, current.list.name),
                    body = pluralStringResource(R.plurals.delete_shared_body, names.size, sharedNames(names)),
                    confirm = stringResource(R.string.delete_shared_btn),
                    dismiss = stringResource(R.string.common_cancel),
                    onConfirm = {
                        onClose()
                        onDelete(current.list.id)
                    },
                    onDismiss = { onClose() },
                )
                return
            }
            AlertDialog(
                onDismissRequest = { onClose() },
                title = { Text(stringResource(R.string.lists_delete_confirm)) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            onClose()
                            onDelete(current.list.id)
                        },
                        modifier = Modifier.testTag(TAG_CONFIRM_DELETE),
                    ) { Text(stringResource(R.string.lists_delete_action)) }
                },
                dismissButton = {
                    TextButton(
                        onClick = { onClose() },
                    ) { Text(stringResource(R.string.common_cancel)) }
                },
            )
        }

        is ListDialog.Leave -> {
            val owner = ownerName(current.list.sharedWith.firstOrNull())
            ConfirmDialog(
                title = stringResource(R.string.leave_title, current.list.name),
                body = stringResource(R.string.leave_body, owner),
                confirm = stringResource(R.string.leave_btn),
                dismiss = stringResource(R.string.common_cancel),
                onConfirm = {
                    onClose()
                    onLeave(current.list.id)
                },
                onDismiss = { onClose() },
            )
        }

        null -> {
            Unit
        }
    }
}

/** « Léa et Tom », « Léa, Tom et 2 autres » au-delà de trois prénoms. */
@Composable
private fun sharedNames(names: List<String>): String =
    if (names.size > MAX_NAMED) {
        stringResource(R.string.sharing_and_others, names.take(2).joinToString(", "), names.size - 2)
    } else {
        joinedNames(names)
    }

private const val MAX_NAMED = 3

@Composable
private fun ListsBody(
    state: ListsUiState,
    onOpen: (String) -> Unit,
    onDialog: (ListDialog) -> Unit,
    top: @Composable () -> Unit = {},
    bottom: @Composable () -> Unit = {},
) {
    when {
        !state.isLoaded -> {
            Unit
        }

        state.lists.isEmpty() -> {
            Column(Modifier.fillMaxSize()) {
                top()
                Box(Modifier.weight(1f)) { EmptyLists() }
                bottom()
            }
        }

        else -> {
            ListsContent(
                lists = state.lists,
                onOpen = onOpen,
                onRename = { onDialog(ListDialog.Rename(it)) },
                onDelete = { onDialog(ListDialog.Delete(it)) },
                onLeave = { onDialog(ListDialog.Leave(it)) },
                top = top,
                bottom = bottom,
            )
        }
    }
}

@Composable
private fun EmptyLists() {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            stringResource(R.string.lists_empty_title),
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            stringResource(R.string.lists_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun ListsContent(
    lists: List<ListSummary>,
    onOpen: (String) -> Unit,
    onRename: (ListSummary) -> Unit,
    onDelete: (ListSummary) -> Unit,
    onLeave: (ListSummary) -> Unit,
    top: @Composable () -> Unit,
    bottom: @Composable () -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag(TAG_LISTS),
        // Place pour le bouton flottant sous la dernière ligne.
        contentPadding = PaddingValues(bottom = 96.dp),
    ) {
        item(key = "invitations", contentType = "invitations") { top() }
        items(lists, key = { it.id }, contentType = { "list" }) { list ->
            ListRow(
                list,
                onOpen = { onOpen(list.id) },
                onRename = { onRename(list) },
                onDelete = { onDelete(list) },
                onLeave = { onLeave(list) },
            )
            HorizontalDivider(color = Ticket.colors.paperEdge)
        }
        item(key = "anonymous", contentType = "hint") { bottom() }
    }
}

@Composable
private fun ListRow(
    list: ListSummary,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onLeave: () -> Unit,
) {
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    val subtitle = subtitle(list)
    val capabilities = SharingDecisions.roleCapabilities(list.role)
    val rowLabel = rowLabel(list, subtitle)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 64.dp)
                .clickable(onClick = onOpen)
                .padding(start = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            Modifier
                .weight(1f)
                .padding(vertical = 8.dp)
                .then(if (rowLabel != null) Modifier.clearAndSetSemantics { contentDescription = rowLabel } else Modifier),
        ) {
            Text(list.name, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = Ticket.colors.ink)
            Text(subtitle, style = TicketType.meta, color = Ticket.colors.inkMuted)
            if (list.isShared) SharingRowBadges(list)
        }
        Box {
            val actions = stringResource(R.string.lists_more_actions, list.name)
            IconButton(onClick = { menuOpen = true }, modifier = Modifier.semantics { contentDescription = actions }) {
                Icon(Icons.Default.MoreVert, contentDescription = null)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                if (capabilities.canRenameList) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.lists_rename)) },
                        onClick = {
                            menuOpen = false
                            onRename()
                        },
                    )
                }
                if (capabilities.canDeleteList) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.lists_delete)) },
                        onClick = {
                            menuOpen = false
                            onDelete()
                        },
                    )
                }
                if (capabilities.canLeave) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.lists_leave), color = Ticket.colors.destructive) },
                        onClick = {
                            menuOpen = false
                            onLeave()
                        },
                        modifier = Modifier.testTag(TAG_LEAVE_LIST),
                    )
                }
            }
        }
    }
}

/** Badge « PARTAGÉE » ou « LECTURE SEULE », puis les initiales des autres membres (décoratifs : voir [rowLabel]). */
@Composable
private fun SharingRowBadges(list: ListSummary) {
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
private fun rowLabel(
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

@Composable
private fun subtitle(list: ListSummary): String =
    when {
        list.total == 0 -> stringResource(R.string.lists_subtitle_empty)
        list.remaining == 0 -> stringResource(R.string.lists_subtitle_done)
        else -> pluralStringResource(R.plurals.lists_subtitle_remaining, list.remaining, list.remaining)
    }

internal const val TAG_NEW_LIST = "newList"
internal const val TAG_SIGN_IN = "lists-sign-in"
internal const val TAG_ABOUT = "about"
internal const val TAG_ABOUT_BADGE = "about-badge"
internal const val TAG_LISTS = "lists"
internal const val TAG_NAME_FIELD = "nameField"
internal const val TAG_CONFIRM_NAME = "confirmName"
internal const val TAG_CONFIRM_DELETE = "confirmDelete"
internal const val TAG_LEAVE_LIST = "leaveList"
