package fr.parcourses.feature.lists

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/** Écran Liste branché sur son [ListDetailViewModel]. */
@Composable
fun ListDetailRoute(
    viewModel: ListDetailViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onStartShopping: ((listId: String) -> Unit)? = null,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    ListDetailScreen(
        state = state,
        input = viewModel.input,
        onSubmit = viewModel::submit,
        onSuggestion = viewModel::add,
        onToggle = viewModel::toggle,
        onDelete = viewModel::delete,
        onBack = onBack,
        onDismissError = viewModel::dismissError,
        modifier = modifier,
        onStartShopping = onStartShopping?.let { start -> { start(viewModel.listId.value) } },
    )
}

/**
 * Écran Liste : articles groupés par rayon, saisie rapide dans un dock en bas. Le bouton « Faire mes courses »
 * n'apparaît que si [onStartShopping] est fourni (mode courses : lot A8).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ListDetailScreen(
    state: ListDetailUiState,
    input: TextFieldState,
    onSubmit: () -> Unit,
    onSuggestion: (ItemSuggestion) -> Unit,
    onToggle: (ItemRow) -> Unit,
    onDelete: (ItemRow) -> Unit,
    onBack: () -> Unit,
    onDismissError: () -> Unit,
    modifier: Modifier = Modifier,
    onStartShopping: (() -> Unit)? = null,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(state.name) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.detail_back),
                        )
                    }
                },
                actions = {
                    if (onStartShopping != null && !state.isMissing) {
                        TextButton(
                            onClick = onStartShopping,
                            enabled = !state.isEmpty,
                            modifier = Modifier.testTag(TAG_SHOP),
                        ) {
                            Text(stringResource(R.string.detail_start_shopping))
                        }
                    }
                },
            )
        },
        bottomBar = {
            if (!state.isMissing) {
                Dock(state.suggestions, input, onSubmit, onSuggestion, focusOnStart = state.isLoaded && state.isEmpty)
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.isMissing -> Placeholder(R.string.detail_missing_title, R.string.detail_missing_body)
                state.isLoaded && state.isEmpty -> Placeholder(R.string.detail_empty_title, R.string.detail_empty_body)
                else -> Sections(state.sections, onToggle, onDelete)
            }
        }
    }
    state.errorDetail?.let { ErrorDialog(it, onDismissError) }
}

@Composable
private fun Placeholder(
    title: Int,
    body: Int,
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(title), style = MaterialTheme.typography.titleLarge)
        Text(
            stringResource(body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Sections(
    sections: List<ItemSection>,
    onToggle: (ItemRow) -> Unit,
    onDelete: (ItemRow) -> Unit,
) {
    LazyColumn(Modifier.fillMaxSize().testTag(TAG_ITEMS)) {
        sections.forEach { section ->
            stickyHeader(key = "header-${section.categoryId}", contentType = "header") {
                SectionHeader(section)
            }
            items(section.items, key = { it.id }, contentType = { "item" }) { row ->
                ItemRowView(row, onToggle = { onToggle(row) }, onDelete = { onDelete(row) })
                HorizontalDivider()
            }
        }
    }
}

@Composable
private fun SectionHeader(section: ItemSection) {
    val announcement = stringResource(R.string.detail_section_count, section.title, section.items.size)
    Text(
        text = section.title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier =
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceContainer)
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics {
                    heading()
                    contentDescription = announcement
                },
    )
}

/**
 * Une ligne : tout le rang est la zone de coche (cible d'au moins 48 dp), l'état se lit sans la couleur (case et
 * texte barré). La suppression passe par un bouton et par l'action d'accessibilité « Supprimer ».
 */
@Composable
private fun ItemRowView(
    row: ItemRow,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
) {
    val checkedText = stringResource(R.string.detail_item_checked)
    val uncheckedText = stringResource(R.string.detail_item_unchecked)
    val deleteLabel = stringResource(R.string.detail_delete_item)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .toggleable(value = row.isChecked, role = Role.Checkbox, onValueChange = { onToggle() })
                .semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    customActions = listOf(CustomAccessibilityAction(deleteLabel) { onDelete().let { true } })
                }.padding(start = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Checkbox(checked = row.isChecked, onCheckedChange = null, modifier = Modifier.clearAndSetSemantics { })
        Text(
            text = row.label,
            style = MaterialTheme.typography.bodyLarge,
            textDecoration = if (row.isChecked) TextDecoration.LineThrough else null,
            color =
                if (row.isChecked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
        )
        row.quantity?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        IconButton(onClick = onDelete, modifier = Modifier.clearAndSetSemantics { }) {
            Icon(Icons.Default.Delete, contentDescription = null)
        }
    }
}

/** Dock de saisie rapide : propositions au-dessus du champ, qui reste ouvert pour enchaîner les articles. */
@Composable
private fun Dock(
    suggestions: List<ItemSuggestion>,
    input: TextFieldState,
    onSubmit: () -> Unit,
    onSuggestion: (ItemSuggestion) -> Unit,
    focusOnStart: Boolean,
) {
    val focus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(focusOnStart) {
        if (focusOnStart && !focused) {
            focus.requestFocus()
            focused = true
        }
    }
    Surface(tonalElevation = 3.dp, modifier = Modifier.imePadding()) {
        Column(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (suggestions.isNotEmpty()) {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.testTag(TAG_SUGGESTIONS),
                ) {
                    items(suggestions, key = { it.id }, contentType = { "suggestion" }) { suggestion ->
                        val label = stringResource(R.string.detail_add_suggestion, suggestion.label)
                        AssistChip(
                            onClick = { onSuggestion(suggestion) },
                            label = { Text(suggestion.label) },
                            modifier = Modifier.sizeIn(minHeight = 48.dp).semantics { contentDescription = label },
                        )
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    state = input,
                    label = { Text(stringResource(R.string.detail_input_label)) },
                    lineLimits = TextFieldLineLimits.SingleLine,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    onKeyboardAction = KeyboardActionHandler { onSubmit() },
                    modifier = Modifier.weight(1f).focusRequester(focus).testTag(TAG_QUICK_ENTRY),
                )
                IconButton(
                    onClick = onSubmit,
                    enabled = input.text.isNotBlank(),
                    modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).testTag(TAG_ADD),
                ) {
                    Icon(Icons.Default.Add, contentDescription = stringResource(R.string.detail_add))
                }
            }
        }
    }
}

internal const val TAG_ITEMS = "items"
internal const val TAG_SUGGESTIONS = "suggestions"
internal const val TAG_QUICK_ENTRY = "quickEntry"
internal const val TAG_ADD = "add"
internal const val TAG_SHOP = "startShopping"
