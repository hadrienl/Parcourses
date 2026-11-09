package fr.parcourses.feature.lists

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
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.repository.ListSummary
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
    )
}

/** Dialogue ouvert sur l'écran Listes. */
private sealed interface ListDialog {
    data object Create : ListDialog

    data class Rename(
        val list: ListSummary,
    ) : ListDialog

    data class Delete(
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
            }
        },
        restore = { saved ->
            when (saved.firstOrNull()) {
                "create" -> ListDialog.Create
                "rename" -> ListDialog.Rename(saved.toList())
                "delete" -> ListDialog.Delete(saved.toList())
                else -> null
            }
        },
    )

private fun ListSummary.toSaved(): List<Any?> = listOf(id, name, remaining, total)

// Une liste sauvegardée : le type du dialogue, puis ses quatre champs.
private const val SAVED_ID = 1
private const val SAVED_NAME = 2
private const val SAVED_REMAINING = 3
private const val SAVED_TOTAL = 4

private fun List<Any?>.toList(): ListSummary =
    ListSummary(
        this[SAVED_ID] as String,
        this[SAVED_NAME] as String,
        this[SAVED_REMAINING] as Int,
        this[SAVED_TOTAL] as Int,
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
) {
    var dialog by rememberSaveable(stateSaver = ListDialogSaver) { mutableStateOf<ListDialog?>(null) }
    // Reprise de compte : la liste visée par un dialogue a changé d'identifiant ou disparu, il se ferme.
    LaunchedEffect(state.lists, state.isLoaded) {
        val target =
            when (val open = dialog) {
                is ListDialog.Rename -> open.list.id
                is ListDialog.Delete -> open.list.id
                else -> null
            }
        if (state.isLoaded && target != null && state.lists.none { it.id == target }) dialog = null
    }
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = { ListsTopBar(onAbout) },
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
            when {
                !state.isLoaded -> {
                    Unit
                }

                state.lists.isEmpty() -> {
                    EmptyLists()
                }

                else -> {
                    ListsContent(
                        lists = state.lists,
                        onOpen = onOpen,
                        onRename = { dialog = ListDialog.Rename(it) },
                        onDelete = { dialog = ListDialog.Delete(it) },
                    )
                }
            }
        }
    }
    ListDialogs(
        dialog = dialog,
        onClose = { dialog = null },
        onCreate = onCreate,
        onRename = onRename,
        onDelete = onDelete,
    )
    state.errorDetail?.let { ErrorDialog(it, onDismissError) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ListsTopBar(onAbout: (() -> Unit)?) {
    TopAppBar(
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Ticket.colors.desk),
        title = { Text(stringResource(R.string.lists_title)) },
        actions = {
            if (onAbout != null) {
                IconButton(onClick = onAbout, modifier = Modifier.testTag(TAG_ABOUT)) {
                    Icon(Icons.Outlined.Info, contentDescription = stringResource(R.string.lists_about))
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

        null -> {
            Unit
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
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize().testTag(TAG_LISTS),
        // Place pour le bouton flottant sous la dernière ligne.
        contentPadding = PaddingValues(bottom = 96.dp),
    ) {
        items(lists, key = { it.id }, contentType = { "list" }) { list ->
            ListRow(list, onOpen = { onOpen(list.id) }, onRename = { onRename(list) }, onDelete = { onDelete(list) })
            HorizontalDivider(color = Ticket.colors.paperEdge)
        }
    }
}

@Composable
private fun ListRow(
    list: ListSummary,
    onOpen: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    var menuOpen by rememberSaveable { mutableStateOf(false) }
    val subtitle = subtitle(list)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 64.dp)
                .clickable(onClick = onOpen)
                .padding(start = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(list.name, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = Ticket.colors.ink)
            Text(subtitle, style = TicketType.meta, color = Ticket.colors.inkMuted)
        }
        Box {
            val actions = stringResource(R.string.lists_more_actions, list.name)
            IconButton(onClick = { menuOpen = true }, modifier = Modifier.semantics { contentDescription = actions }) {
                Icon(Icons.Default.MoreVert, contentDescription = null)
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.lists_rename)) },
                    onClick = {
                        menuOpen = false
                        onRename()
                    },
                )
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.lists_delete)) },
                    onClick = {
                        menuOpen = false
                        onDelete()
                    },
                )
            }
        }
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
internal const val TAG_ABOUT = "about"
internal const val TAG_LISTS = "lists"
internal const val TAG_NAME_FIELD = "nameField"
internal const val TAG_CONFIRM_NAME = "confirmName"
internal const val TAG_CONFIRM_DELETE = "confirmDelete"
