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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.repository.ListSummary

/** Écran Listes branché sur son [ListsViewModel]. */
@Composable
fun ListsRoute(
    viewModel: ListsViewModel,
    onOpen: (String) -> Unit,
    modifier: Modifier = Modifier,
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

/** Écran Listes : état vide, création, renommage, suppression. Sans état propre hors dialogues. */
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
    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text(stringResource(R.string.lists_title)) }) },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { dialog = ListDialog.Create },
                icon = { Icon(Icons.Default.Add, contentDescription = null) },
                text = { Text(stringResource(R.string.lists_new)) },
                modifier = Modifier.testTag(TAG_NEW_LIST),
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
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
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.lists_empty_title), style = MaterialTheme.typography.titleLarge)
        Text(
            stringResource(R.string.lists_empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
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
            HorizontalDivider()
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
            Text(list.name, style = MaterialTheme.typography.titleMedium)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
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

@Composable
private fun NameDialog(
    title: String,
    confirmLabel: String,
    initialName: String,
    onConfirm: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    // Curseur en fin de nom : on complète un nom existant plus souvent qu'on ne le réécrit.
    var name by rememberSaveable(stateSaver = TextFieldValue.Saver) {
        mutableStateOf(TextFieldValue(initialName, TextRange(initialName.length)))
    }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text(stringResource(R.string.lists_name_label)) },
                singleLine = true,
                keyboardOptions =
                    KeyboardOptions(
                        capitalization = KeyboardCapitalization.Sentences,
                        imeAction = ImeAction.Done,
                    ),
                modifier = Modifier.focusRequester(focus).testTag(TAG_NAME_FIELD),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.text) },
                enabled = ListsViewModel.isValid(name.text),
                modifier = Modifier.testTag(TAG_CONFIRM_NAME),
            ) { Text(confirmLabel) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_cancel)) } },
    )
}

@Composable
internal fun ErrorDialog(
    detail: String,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.common_error_title)) },
        text = { Text(stringResource(R.string.common_error_message, detail)) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.common_ok)) } },
    )
}

internal const val TAG_NEW_LIST = "newList"
internal const val TAG_LISTS = "lists"
internal const val TAG_NAME_FIELD = "nameField"
internal const val TAG_CONFIRM_NAME = "confirmName"
internal const val TAG_CONFIRM_DELETE = "confirmDelete"
