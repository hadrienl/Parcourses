package fr.parcourses.feature.lists

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
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
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.designsystem.AisleLine
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.DockPill
import fr.parcourses.core.designsystem.ItemLine
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.ThreadPiece
import fr.parcourses.core.designsystem.ThreadStyle
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketCheckBox
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketHeader
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.dockFieldColors
import fr.parcourses.core.designsystem.dockFieldTextStyle
import fr.parcourses.core.designsystem.isLargeText
import fr.parcourses.core.designsystem.thread
import fr.parcourses.core.designsystem.threadSegments

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
 * Écran Liste (#6, B3) : un ticket, articles groupés par rayon le long du fil, saisie rapide dans la barre flottante en
 * bas. « Faire mes courses » est le bouton d'action à côté, à portée du pouce ; il n'apparaît que si
 * [onStartShopping] est fourni et que la liste a des articles.
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
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.desk),
                title = { Text(state.name) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.detail_back),
                        )
                    }
                },
            )
        },
        bottomBar = {
            if (!state.isMissing) {
                Dock(
                    suggestions = state.suggestions,
                    input = input,
                    onSubmit = onSubmit,
                    onSuggestion = onSuggestion,
                    focusOnStart = state.isLoaded && state.isEmpty,
                    onStartShopping = onStartShopping.takeIf { !state.isEmpty },
                )
            }
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
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
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            stringResource(title),
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            stringResource(body),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            textAlign = TextAlign.Center,
        )
    }
}

/** Les rayons et leurs articles le long du fil, encore à parcourir : la liste se prépare, rien n'est parcouru. */
@Composable
private fun Sections(
    sections: List<ItemSection>,
    onToggle: (ItemRow) -> Unit,
    onDelete: (ItemRow) -> Unit,
) {
    val total = sections.sumOf { it.items.size }
    val count = pluralStringResource(R.plurals.detail_item_count, total, total)
    val stops = sections.sumOf { it.items.size + 1 }
    val segments = threadSegments(stops, next = 0)
    LazyColumn(
        Modifier.fillMaxSize().testTag(TAG_ITEMS),
        contentPadding = PaddingValues(bottom = TicketDimens.spaceL),
    ) {
        item(key = "header", contentType = "header") {
            TicketHeader(
                title = null,
                meta = emptyList(),
                totalLabel = stringResource(R.string.detail_total_label),
                total = total,
                modifier = Modifier.clearAndSetSemantics { contentDescription = count },
            )
        }
        var index = 0
        sections.forEach { section ->
            val (top, bottom) = segments[index++]
            item(key = "header-${section.categoryId}", contentType = "aisle") {
                SectionHeader(section, ThreadPiece(top, bottom))
            }
            section.items.forEach { row ->
                val (rowTop, rowBottom) = segments[index++]
                item(key = row.id, contentType = "item") {
                    ItemRowView(
                        row,
                        ThreadPiece(rowTop, rowBottom, if (row.isChecked) Bead.Checked else Bead.Idle),
                        onToggle = { onToggle(row) },
                        onDelete = { onDelete(row) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SectionHeader(
    section: ItemSection,
    piece: ThreadPiece,
) {
    val announcement = stringResource(R.string.detail_section_count, section.title, section.items.size)
    AisleLine(
        categoryId = section.categoryId,
        title = section.title,
        piece = piece,
        style = ThreadStyle.Solid,
        modifier =
            Modifier.clearAndSetSemantics {
                heading()
                contentDescription = announcement
                text = AnnotatedString(section.title)
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
    piece: ThreadPiece,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
) {
    val colors = Ticket.colors
    val checkedText = stringResource(R.string.detail_item_checked)
    val uncheckedText = stringResource(R.string.detail_item_unchecked)
    val deleteLabel = stringResource(R.string.detail_delete_item)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .thread(piece, ThreadStyle.Solid)
                .heightIn(min = TicketDimens.rowMin)
                .toggleable(value = row.isChecked, role = Role.Checkbox, onValueChange = { onToggle() })
                .semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    customActions = listOf(CustomAccessibilityAction(deleteLabel) { onDelete().let { true } })
                }.padding(start = ThreadLayout.contentStart),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TicketCheckBox(row.isChecked)
        ItemLine(
            name = row.label,
            quantity = row.quantity,
            style = TicketType.item,
            color = if (row.isChecked) colors.checked else colors.ink,
            decoration = if (row.isChecked) TextDecoration.LineThrough else null,
            modifier =
                Modifier
                    .weight(1f)
                    .padding(start = TicketDimens.spaceS, top = 6.dp, bottom = 6.dp),
        )
        IconButton(onClick = onDelete, modifier = Modifier.clearAndSetSemantics { }) {
            Icon(Icons.Default.Delete, contentDescription = null, tint = colors.inkMuted)
        }
    }
}

/**
 * Bas de l'écran : propositions au-dessus, barre flottante de saisie (qui reste ouverte pour enchaîner les articles)
 * et bouton « Faire mes courses ». Empilés quand le texte est très agrandi.
 */
@Composable
private fun Dock(
    suggestions: List<ItemSuggestion>,
    input: TextFieldState,
    onSubmit: () -> Unit,
    onSuggestion: (ItemSuggestion) -> Unit,
    focusOnStart: Boolean,
    onStartShopping: (() -> Unit)?,
) {
    val focus = remember { FocusRequester() }
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(focusOnStart) {
        if (focusOnStart && !focused) {
            focus.requestFocus()
            focused = true
        }
    }
    val stacked = isLargeText()
    Column(
        Modifier
            .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        if (suggestions.isNotEmpty()) Suggestions(suggestions, onSuggestion)
        val field: @Composable (Modifier) -> Unit = { modifier -> EntryField(input, onSubmit, focus, modifier) }
        // Libellé court à l'écran (« Courses », comme la maquette) ; le nom complet le contient (WCAG 2.5.3).
        val shopLabel = stringResource(R.string.detail_start_shopping)
        val shop: @Composable (Modifier) -> Unit = { modifier ->
            if (onStartShopping != null) {
                ExtendedFloatingActionButton(
                    onClick = onStartShopping,
                    icon = { Icon(Icons.Default.ShoppingCart, contentDescription = null) },
                    text = { Text(stringResource(R.string.detail_start_shopping_short)) },
                    containerColor = Ticket.colors.accent,
                    contentColor = Ticket.colors.onAccent,
                    modifier =
                        modifier
                            .heightIn(min = TicketDimens.primaryAction)
                            .semantics { contentDescription = shopLabel }
                            .testTag(TAG_SHOP),
                )
            }
        }
        if (stacked) {
            field(Modifier.fillMaxWidth())
            shop(Modifier.fillMaxWidth())
        } else {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
            ) {
                field(Modifier.weight(1f))
                shop(Modifier)
            }
        }
    }
}

/** Propositions d'articles, au-dessus de la barre de saisie. */
@Composable
private fun Suggestions(
    suggestions: List<ItemSuggestion>,
    onSuggestion: (ItemSuggestion) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
        modifier = Modifier.testTag(TAG_SUGGESTIONS),
    ) {
        items(suggestions, key = { it.id }, contentType = { "suggestion" }) { suggestion ->
            val label = stringResource(R.string.detail_add_suggestion, suggestion.label)
            AssistChip(
                onClick = { onSuggestion(suggestion) },
                label = { Text(suggestion.label) },
                colors = AssistChipDefaults.assistChipColors(containerColor = Ticket.colors.paper),
                modifier = Modifier.sizeIn(minHeight = 48.dp).semantics { contentDescription = label },
            )
        }
    }
}

/** Saisie rapide : le champ dans la barre flottante, et son bouton « Ajouter ». */
@Composable
private fun EntryField(
    input: TextFieldState,
    onSubmit: () -> Unit,
    focus: FocusRequester,
    modifier: Modifier,
) {
    DockPill(modifier) {
        TextField(
            state = input,
            label = { Text(stringResource(R.string.detail_input_label), fontFamily = FontFamily.Default) },
            textStyle = dockFieldTextStyle(),
            lineLimits = TextFieldLineLimits.SingleLine,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            onKeyboardAction = KeyboardActionHandler { onSubmit() },
            colors = dockFieldColors(),
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

internal const val TAG_ITEMS = "items"
internal const val TAG_SUGGESTIONS = "suggestions"
internal const val TAG_QUICK_ENTRY = "quickEntry"
internal const val TAG_ADD = "add"
internal const val TAG_SHOP = "startShopping"
