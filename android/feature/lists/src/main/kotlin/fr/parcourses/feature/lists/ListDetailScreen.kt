package fr.parcourses.feature.lists

import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.indication
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
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
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
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
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.designsystem.AisleLine
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.DockPill
import fr.parcourses.core.designsystem.ItemEditSheet
import fr.parcourses.core.designsystem.ItemLine
import fr.parcourses.core.designsystem.LocalThreadTrack
import fr.parcourses.core.designsystem.RowLane
import fr.parcourses.core.designsystem.ThreadBead
import fr.parcourses.core.designsystem.ThreadGutter
import fr.parcourses.core.designsystem.ThreadLayout
import fr.parcourses.core.designsystem.ThreadPath
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
import fr.parcourses.core.designsystem.pressScale
import fr.parcourses.core.designsystem.rememberThreadTrackState
import fr.parcourses.core.designsystem.threadTrack
import kotlinx.coroutines.launch
import fr.parcourses.core.designsystem.R as DesignR

/** Écran Liste branché sur son [ListDetailViewModel]. */
@Composable
fun ListDetailRoute(
    viewModel: ListDetailViewModel,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    onStartShopping: ((listId: String) -> Unit)? = null,
    onShare: ((listId: String) -> Unit)? = null,
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
        onShare = onShare?.let { share -> { share(viewModel.listId.value) } },
        onAcknowledge = viewModel::acknowledge,
        itemEditing =
            remember(viewModel) {
                ItemEditing(
                    onEdit = viewModel::openItemEditor,
                    onSave = viewModel::saveItem,
                    onClose = viewModel::closeItemEditor,
                    onDismissTip = viewModel::dismissQuantityTip,
                )
            },
    )
}

/**
 * Panneau de l'article (#110) : [onEdit] l'ouvre (appui long, action TalkBack), [onSave] reçoit le texte des deux
 * champs, [onClose] le referme sans rien écrire. [onDismissTip] ferme l'astuce pour toujours.
 */
class ItemEditing(
    val onEdit: (ItemRow) -> Unit = {},
    val onSave: (label: String, quantityText: String) -> Unit = { _, _ -> },
    val onClose: () -> Unit = {},
    val onDismissTip: () -> Unit = {},
)

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
    onShare: (() -> Unit)? = null,
    onAcknowledge: (AccessChange) -> Unit = {},
    itemEditing: ItemEditing = ItemEditing(),
) {
    val colors = Ticket.colors
    val sharing = state.sharing
    val capabilities = sharing.capabilities
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    // « Lecture seule : cette liste ne se modifie pas ici. » une seule fois par ouverture.
    var readOnlyHinted by rememberSaveable { mutableStateOf(false) }
    val readOnlyText = stringResource(R.string.ro_tap)
    val onReadOnlyTap = {
        if (!readOnlyHinted) {
            readOnlyHinted = true
            scope.launch { snackbar.showSnackbar(readOnlyText) }
        }
    }
    val upgrade = sharing.notice as? AccessChange.Upgraded
    val upgradeText = upgrade?.let { stringResource(R.string.ro_upgrade, ownerName(it.ownerName)) }
    LaunchedEffect(upgrade) {
        if (upgrade != null && upgradeText != null) {
            onAcknowledge(upgrade)
            snackbar.showSnackbar(upgradeText)
        }
    }
    val removed = (sharing.notice as? AccessChange.Removed)?.takeIf { state.isMissing }
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            DetailTopBar(state, onBack, onShare.takeIf { !state.isMissing })
        },
        bottomBar = { DetailBottomBar(state, input, onSubmit, onSuggestion, onStartShopping) },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
            val actions = ItemActions(!capabilities.canEditItems, onToggle, onDelete, onReadOnlyTap, itemEditing.onEdit)
            DetailContent(state, removed, actions, onAcknowledge, onBack, itemEditing.onDismissTip)
        }
    }
    state.editing?.let { target -> ItemEditSheet(target, onSave = itemEditing.onSave, onDismiss = itemEditing.onClose) }
    state.errorDetail?.let { ErrorDialog(it, onDismissError) }
}

/** Bas de l'écran : la saisie et « Courses », ou la note d'un lecteur ; rien pour une liste disparue. */
@Composable
private fun DetailBottomBar(
    state: ListDetailUiState,
    input: TextFieldState,
    onSubmit: () -> Unit,
    onSuggestion: (ItemSuggestion) -> Unit,
    onStartShopping: (() -> Unit)?,
) {
    val capabilities = state.sharing.capabilities
    when {
        state.isMissing -> {
            Unit
        }

        !capabilities.canEditItems -> {
            ReadOnlyNote(state.sharing.ownerName, Modifier.windowInsetsPadding(WindowInsets.navigationBars))
        }

        else -> {
            Dock(
                suggestions = state.suggestions,
                input = input,
                onSubmit = onSubmit,
                onSuggestion = onSuggestion,
                focusOnStart = state.isLoaded && state.isEmpty,
                onStartShopping = onStartShopping.takeIf { !state.isEmpty && capabilities.canShop },
            )
        }
    }
}

/** Le ticket : liste retirée, introuvable, vide, ou ses rayons sous les bandeaux du partage. */
@Composable
private fun DetailContent(
    state: ListDetailUiState,
    removed: AccessChange.Removed?,
    actions: ItemActions,
    onAcknowledge: (AccessChange) -> Unit,
    onBack: () -> Unit,
    onDismissTip: () -> Unit,
) {
    when {
        removed != null -> {
            RemovedState(removed) {
                onAcknowledge(removed)
                onBack()
            }
        }

        state.isMissing -> {
            Placeholder(R.string.detail_missing_title, R.string.detail_missing_body)
        }

        else -> {
            Column(Modifier.fillMaxSize()) {
                SharingBanners(state.sharing, onAcknowledge)
                if (state.showsQuantityTip) QuantityTip(onDismissTip)
                Box(Modifier.weight(1f)) {
                    if (state.isLoaded && state.isEmpty) {
                        Placeholder(R.string.detail_empty_title, R.string.detail_empty_body)
                    } else {
                        Sections(state.sections, actions, lastChange = state.sharing.lastChange)
                    }
                }
            }
        }
    }
}

/**
 * Ce qu'une ligne d'article peut faire : en lecture seule, un appui rappelle seulement que rien ne se modifie. [onEdit]
 * ouvre le panneau de l'article (appui long, action TalkBack), jamais pour un lecteur.
 */
private class ItemActions(
    val readOnly: Boolean,
    val onToggle: (ItemRow) -> Unit,
    val onDelete: (ItemRow) -> Unit,
    val onReadOnlyTap: () -> Unit,
    val onEdit: (ItemRow) -> Unit,
)

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
    actions: ItemActions,
    lastChange: LastChange?,
) {
    val total = sections.sumOf { it.items.size }
    val count = pluralStringResource(R.plurals.detail_item_count, total, total)
    val listState = rememberLazyListState()
    val track = rememberThreadTrackState()
    // Les arrêts du fil suivent l'en-tête du ticket et, s'il y en a une, la ligne du dernier changement.
    val path =
        ThreadPath(
            keys = sections.flatMap { section -> listOf(section.threadKey) + section.items.map(ItemRow::id) },
            startIndex = if (lastChange != null) 2 else 1,
            next = 0,
            style = ThreadStyle.Solid,
        )
    // Le trait est dessiné une fois, derrière les lignes ; chaque ligne ne porte que sa perle (#115).
    CompositionLocalProvider(LocalThreadTrack provides track) {
        LazyColumn(
            Modifier.fillMaxSize().threadTrack(track, listState, path).testTag(TAG_ITEMS),
            state = listState,
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
            if (lastChange != null) {
                item(key = "last-change", contentType = "meta") { LastChangeLine(lastChange) }
            }
            sections.forEach { section ->
                item(key = section.threadKey, contentType = "aisle") { SectionHeader(section) }
                section.items.forEach { row ->
                    item(key = row.id, contentType = "item") {
                        val bead = if (row.isChecked) Bead.Checked else Bead.Idle
                        if (actions.readOnly) {
                            ReadOnlyItemRow(row, bead, onTap = actions.onReadOnlyTap)
                        } else {
                            ItemRowView(
                                row,
                                bead,
                                onToggle = { actions.onToggle(row) },
                                onDelete = { actions.onDelete(row) },
                                onEdit = { actions.onEdit(row) },
                            )
                        }
                    }
                }
            }
        }
    }
}

/** Clé `LazyColumn` du titre d'un rayon, arrêt du fil. */
private val ItemSection.threadKey: String get() = "header-$categoryId"

@Composable
private fun SectionHeader(section: ItemSection) {
    val announcement = stringResource(R.string.detail_section_count, section.title, section.items.size)
    AisleLine(
        categoryId = section.categoryId,
        title = section.title,
        threadKey = section.threadKey,
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
 * texte barré). La suppression passe par un bouton et par l'action d'accessibilité « Supprimer ». Un appui long ouvre
 * le panneau de l'article (#110) : la case et le texte s'enfoncent pendant l'appui, une vibration marque le
 * déclenchement ; TalkBack l'offre aussi en action « Modifier la quantité ». La gouttière (perle) ne bouge jamais :
 * l'ondulation et l'enfoncement restent dans le couloir (#115).
 */
@Suppress("LongMethod") // Une ligne : gestes, sémantique TalkBack et contenu se lisent ensemble.
@Composable
private fun ItemRowView(
    row: ItemRow,
    bead: Bead,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onEdit: () -> Unit,
) {
    val colors = Ticket.colors
    val checkedText = stringResource(R.string.detail_item_checked)
    val uncheckedText = stringResource(R.string.detail_item_unchecked)
    val deleteLabel = stringResource(R.string.detail_delete_item)
    val editLabel = stringResource(DesignR.string.item_edit_action)
    val label = spokenLabel(row)
    val interaction = remember { MutableInteractionSource() }
    val scale = pressScale(interaction)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .combinedClickable(
                    interactionSource = interaction,
                    indication = null,
                    role = Role.Checkbox,
                    onLongClickLabel = editLabel,
                    onLongClick = onEdit,
                    hapticFeedbackEnabled = true,
                    onClick = onToggle,
                ).semantics(mergeDescendants = true) {
                    contentDescription = label
                    toggleableState = ToggleableState(row.isChecked)
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    // « Modifier la quantité » est l'appui long libellé ci-dessus : pas d'action en double.
                    customActions = listOf(CustomAccessibilityAction(deleteLabel) { onDelete().let { true } })
                }.padding(start = ThreadLayout.start),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ThreadGutter(row.id) { ThreadBead(bead) }
        RowLane {
            Row(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .indication(interaction, ripple())
                        .heightIn(min = TicketDimens.rowMin)
                        .padding(start = TicketDimens.spaceXs),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Seuls la case et le texte s'enfoncent pendant l'appui (#110), depuis leur bord de début, comme la
                // marque d'auteur et la corbeille restent en place.
                Row(
                    modifier =
                        Modifier
                            .weight(1f)
                            .graphicsLayer {
                                scaleX = scale.value
                                scaleY = scale.value
                                transformOrigin = PRESS_ORIGIN
                            }.testTag(TAG_ITEM_CONTENT),
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
                }
                AuthorMark(row.authorMark)
                IconButton(onClick = onDelete, modifier = Modifier.clearAndSetSemantics { }) {
                    Icon(Icons.Default.Delete, contentDescription = null, tint = colors.inkMuted)
                }
            }
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
    // Lu à travers `derivedStateOf` : seul le passage vide ↔ non vide recompose le bouton, pas chaque frappe (#54).
    val canSubmit by remember(input) { derivedStateOf { input.text.isNotBlank() } }
    DockPill(modifier) {
        TextField(
            state = input,
            // Invite (#110) : « Ajouter un article », puis l'exemple « ex. : 2 lait » dans le champ dès qu'il a le
            // focus. Le texte complet ne tient pas sur une ligne à côté du bouton « Courses ».
            label = { Text(stringResource(R.string.detail_input_label), fontFamily = FontFamily.Default) },
            placeholder = { Text(stringResource(R.string.detail_input_example), fontFamily = FontFamily.Default) },
            textStyle = dockFieldTextStyle(),
            lineLimits = TextFieldLineLimits.SingleLine,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            onKeyboardAction = KeyboardActionHandler { onSubmit() },
            colors = dockFieldColors(),
            modifier = Modifier.weight(1f).focusRequester(focus).testTag(TAG_QUICK_ENTRY),
        )
        IconButton(
            onClick = onSubmit,
            enabled = canSubmit,
            modifier = Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp).testTag(TAG_ADD),
        ) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.detail_add))
        }
    }
}

internal const val TAG_ITEMS = "items"
internal const val TAG_SUGGESTIONS = "suggestions"
internal const val TAG_QUICK_ENTRY = "quickEntry"
internal const val TAG_ITEM_CONTENT = "itemContent"

internal const val TAG_ADD = "add"
internal const val TAG_SHOP = "startShopping"
internal const val TAG_QUANTITY_TIP = "quantityTip"
internal const val TAG_QUANTITY_TIP_CLOSE = "quantityTipClose"

/** Origine de l'enfoncement de la case et du texte : leur bord gauche, à mi-hauteur, côté fil. */
private val PRESS_ORIGIN = TransformOrigin(0f, 0.5f)
