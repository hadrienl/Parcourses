package fr.parcourses.feature.shopping

import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/** Ce que l'écran peut demander. Une seule valeur à passer, stable d'une recomposition à l'autre. */
class ShoppingActions(
    val onBack: () -> Unit = {},
    val onToggle: (ShoppingRow) -> Unit = {},
    val onNotFound: (ShoppingRow) -> Unit = {},
    val onRestore: (ShoppingRow) -> Unit = {},
    val onSubmit: () -> Unit = {},
    val onUndo: () -> Unit = {},
    val onFinish: (keepRemaining: Boolean) -> Unit = {},
    val onDismissError: () -> Unit = {},
    val onScrolling: (Boolean) -> Unit = {},
    val onEditing: (Boolean) -> Unit = {},
    val onAnnouncementShown: (Int) -> Unit = {},
    val onClose: () -> Unit = {},
    /** Retour haptique d'une coche (appelé avant [onToggle], seulement pour cocher). */
    val onCheckFeedback: () -> Unit = {},
)

/**
 * Mode courses. [reduceMotion] : « réduire les animations » du système, les glissements deviennent un fondu de
 * 150 ms. Avec un résumé, l'écran de fin minimal prend la place (l'écran complet est le lot A9).
 */
@Composable
fun ShoppingScreen(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    reduceMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val summary = state.summary
    if (summary != null) {
        ShoppingSummaryScreen(summary, actions.onClose, modifier)
    } else {
        ShoppingContent(state, input, actions, reduceMotion, modifier)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShoppingContent(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    reduceMotion: Boolean,
    modifier: Modifier,
) {
    var showsRemaining by rememberSaveable { mutableStateOf(false) }
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(state.name) },
                navigationIcon = {
                    IconButton(onClick = actions.onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.shopping_back),
                        )
                    }
                },
            )
        },
        bottomBar = {
            Dock(
                state = state,
                input = input,
                actions = actions,
                onFinish = { if (state.remainingCount > 0) showsRemaining = true else actions.onFinish(true) },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            ShoppingList(state, actions, reduceMotion)
            ReorderAnnouncementNode(state.reorder, actions.onAnnouncementShown)
        }
    }
    if (showsRemaining || state.expired) {
        RemainingItemsSheet(
            count = state.remainingCount,
            expired = state.expired,
            actions = actions,
            onCancel = { showsRemaining = false },
        )
    }
    state.errorMessage?.let { ErrorDialog(it, actions.onDismissError) }
}

/** Nœud d'annonce : poli, jamais focalisable, de la taille d'un point. Il ne vole pas le focus de TalkBack. */
@Composable
private fun ReorderAnnouncementNode(
    reorder: ReorderAnnouncement?,
    onShown: (Int) -> Unit,
) {
    if (reorder == null) return
    val text = stringResource(R.string.shopping_reordered, reorder.next)
    Box(
        Modifier
            .size(1.dp)
            .testTag(TAG_ANNOUNCEMENT)
            .semantics {
                liveRegion = LiveRegionMode.Polite
                contentDescription = text
            },
    )
    LaunchedEffect(reorder.seq) {
        delay(ANNOUNCEMENT_MS)
        onShown(reorder.seq)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ShoppingList(
    state: ShoppingUiState,
    actions: ShoppingActions,
    reduceMotion: Boolean,
) {
    val listState = rememberLazyListState()
    var basketExpanded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(listState) { snapshotFlow { listState.isScrollInProgress }.collect(actions.onScrolling) }
    LazyColumn(Modifier.fillMaxSize().testTag(TAG_ITEMS), state = listState) {
        item(key = "header", contentType = "header") { Header(state) }
        if (state.groupsByAisle) {
            state.sections.forEach { section ->
                stickyHeader(key = "aisle-${section.aisleId}", contentType = "aisle") { AisleHeader(section) }
                rows(section.rows, state, actions, reduceMotion)
            }
        } else {
            rows(state.toBuy, state, actions, reduceMotion)
        }
        if (state.notFound.isNotEmpty()) {
            item(key = "not-found-header", contentType = "title") {
                SectionTitle(stringResource(R.string.shopping_not_found_title))
            }
            items(state.notFound, key = { it.id }, contentType = { "not-found" }) { row ->
                NotFoundRow(row, { actions.onRestore(row) }, rowAnimation(reduceMotion))
                HorizontalDivider()
            }
        }
        if (state.basket.isNotEmpty()) {
            item(key = "basket-header", contentType = "basket") {
                BasketHeader(state.basket.size, basketExpanded) { basketExpanded = !basketExpanded }
            }
            if (basketExpanded) rows(state.basket, state, actions, reduceMotion)
        }
    }
}

private fun LazyListScope.rows(
    rows: List<ShoppingRow>,
    state: ShoppingUiState,
    actions: ShoppingActions,
    reduceMotion: Boolean,
) {
    items(rows, key = { it.id }, contentType = { "row" }) { row ->
        ItemRow(
            row = row,
            highlighted = state.highlightedItemId == row.id,
            actions = actions,
            modifier = rowAnimation(reduceMotion),
        )
        HorizontalDivider()
    }
}

/** Réordonnancement animé ; « réduire les animations » : plus de glissement, un fondu de 150 ms (#10 §8.2). */
private fun LazyItemScope.rowAnimation(reduceMotion: Boolean): Modifier =
    if (reduceMotion) {
        Modifier.animateItem(fadeInSpec = tween(FADE_MS), placementSpec = null, fadeOutSpec = tween(FADE_MS))
    } else {
        Modifier.animateItem()
    }

@Composable
private fun Header(state: ShoppingUiState) {
    val knowledge =
        when (val k = state.knowledge) {
            RouteKnowledge.NoStore -> stringResource(R.string.shopping_knowledge_no_store)
            RouteKnowledge.Unknown -> stringResource(R.string.shopping_knowledge_unknown)
            is RouteKnowledge.Learning -> stringResource(R.string.shopping_knowledge_learning, k.percent)
            is RouteKnowledge.Learned -> stringResource(R.string.shopping_knowledge_learned, k.percent)
        }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) { heading() }
            .testTag(TAG_HEADER),
    ) {
        Text(
            stringResource(R.string.shopping_remaining_header, state.toBuyCount),
            style = MaterialTheme.typography.titleLarge,
        )
        state.storeName?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
        Text(knowledge, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Titre de rayon : lu comme un en-tête, avec le nombre d'articles à prendre. */
@Composable
private fun AisleHeader(section: ShoppingSection) {
    val announcement = stringResource(R.string.shopping_aisle_count, section.title, section.remainingCount)
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

@Composable
private fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
    )
}

@Composable
private fun BasketHeader(
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val title = stringResource(R.string.shopping_basket, count)
    val state =
        stringResource(if (expanded) R.string.shopping_basket_expanded else R.string.shopping_basket_collapsed)
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(role = Role.Button, onClick = onToggle)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .testTag(TAG_BASKET)
                .semantics { stateDescription = state },
    )
}

/**
 * Une ligne. Action par défaut : « Cocher » (ou « Décocher » si la ligne l'est déjà). Actions personnalisées pour
 * TalkBack : « Décocher » sur une ligne cochée, « Pas trouvé » sur une ligne à prendre ; le balayage n'est jamais la
 * seule voie. Le balayage : à droite coche, à gauche signale introuvable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ItemRow(
    row: ShoppingRow,
    highlighted: Boolean,
    actions: ShoppingActions,
    modifier: Modifier = Modifier,
) {
    val swipe =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                when (value) {
                    SwipeToDismissBoxValue.StartToEnd -> {
                        if (!row.isChecked) {
                            actions.onCheckFeedback()
                            actions.onToggle(row)
                        }
                    }

                    SwipeToDismissBoxValue.EndToStart -> {
                        if (!row.isChecked) actions.onNotFound(row)
                    }

                    SwipeToDismissBoxValue.Settled -> {
                        Unit
                    }
                }
                // La ligne revient à sa place : c'est la liste qui change, pas le geste.
                false
            },
        )
    SwipeToDismissBox(
        state = swipe,
        modifier = modifier,
        enableDismissFromStartToEnd = !row.isChecked,
        enableDismissFromEndToStart = !row.isChecked,
        backgroundContent = {},
    ) {
        ItemRowContent(row, highlighted, actions)
    }
}

@Composable
private fun ItemRowContent(
    row: ShoppingRow,
    highlighted: Boolean,
    actions: ShoppingActions,
) {
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
                .background(
                    if (highlighted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
                ).heightIn(min = 48.dp)
                .clickable(onClickLabel = if (row.isChecked) uncheckLabel else checkLabel, role = Role.Checkbox) {
                    if (!row.isChecked) actions.onCheckFeedback()
                    actions.onToggle(row)
                }.semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    customActions = custom
                }.padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // L'état se lit sans couleur : forme de l'icône et texte barré.
        Checkbox(checked = row.isChecked, onCheckedChange = null, modifier = Modifier.clearAndSetSemantics { })
        Text(
            text = row.label,
            style = MaterialTheme.typography.bodyLarge,
            textDecoration = if (row.isChecked) TextDecoration.LineThrough else null,
            color =
                if (row.isChecked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
        )
        row.quantity?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun NotFoundRow(
    row: ShoppingRow,
    onRestore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = stringResource(R.string.shopping_state_not_found)
    val hint = stringResource(R.string.shopping_restore_hint)
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(onClickLabel = hint, role = Role.Button, onClick = onRestore)
                .semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = state
                }.padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Info, contentDescription = null, modifier = Modifier.clearAndSetSemantics { })
        Text(row.label, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
        Text(
            stringResource(R.string.shopping_restore),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Dock en bas : annulation, saisie et « Terminer ». Empilé quand le texte est très agrandi (200 %). */
@Composable
private fun Dock(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    onFinish: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(focused) {
        snapshotFlow { input.text.isNotEmpty() }.collect { actions.onEditing(focused) }
    }
    val stacked = LocalDensity.current.fontScale >= STACK_FONT_SCALE
    Surface(tonalElevation = 3.dp, modifier = Modifier.imePadding()) {
        Column(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.undo?.let { UndoBanner(it, actions.onUndo) }
            if (state.isEverythingChecked) {
                Text(stringResource(R.string.shopping_all_checked), style = MaterialTheme.typography.titleMedium)
            }
            val field: @Composable (Modifier) -> Unit = { modifier ->
                OutlinedTextField(
                    state = input,
                    label = { Text(stringResource(R.string.shopping_input_label)) },
                    lineLimits = TextFieldLineLimits.SingleLine,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    onKeyboardAction = KeyboardActionHandler { actions.onSubmit() },
                    trailingIcon = {
                        IconButton(onClick = actions.onSubmit, enabled = input.text.isNotBlank()) {
                            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.shopping_add))
                        }
                    },
                    modifier = modifier.onFocusChanged { focused = it.isFocused }.testTag(TAG_ENTRY),
                )
            }
            val finish: @Composable (Modifier) -> Unit = { modifier ->
                Button(onClick = onFinish, modifier = modifier.heightIn(min = 48.dp).testTag(TAG_FINISH)) {
                    Text(stringResource(R.string.shopping_finish))
                }
            }
            if (stacked) {
                field(Modifier.fillMaxWidth())
                finish(Modifier.fillMaxWidth())
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    field(Modifier.weight(1f))
                    finish(Modifier)
                }
            }
        }
    }
}

@Composable
private fun UndoBanner(
    undo: ShoppingUndo,
    onUndo: () -> Unit,
) {
    val message =
        when (undo.kind) {
            ShoppingUndo.Kind.Check -> stringResource(R.string.shopping_undo_checked, undo.label)
            ShoppingUndo.Kind.NotFound -> stringResource(R.string.shopping_undo_not_found, undo.label)
        }
    Snackbar(
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag(TAG_UNDO_BANNER),
        action = {
            TextButton(onClick = onUndo, modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_UNDO)) {
                Text(stringResource(R.string.shopping_undo))
            }
        },
    ) {
        Text(message)
    }
}

/** « 2 articles non cochés : les garder pour la prochaine fois ? » (#6) */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RemainingItemsSheet(
    count: Int,
    expired: Boolean,
    actions: ShoppingActions,
    onCancel: () -> Unit,
) {
    val sheet =
        rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { !expired })
    ModalBottomSheet(onDismissRequest = { if (!expired) onCancel() }, sheetState = sheet) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp).testTag(TAG_REMAINING_SHEET),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                pluralStringResource(R.plurals.shopping_remaining_title, count, count),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            if (expired) Text(stringResource(R.string.shopping_expired_note))
            Text(stringResource(R.string.shopping_remaining_question))
            Button(
                onClick = { actions.onFinish(true) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_KEEP),
            ) { Text(stringResource(R.string.shopping_keep)) }
            OutlinedButton(
                onClick = { actions.onFinish(false) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_DROP),
            ) { Text(stringResource(R.string.shopping_drop)) }
            if (!expired) {
                TextButton(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_CONTINUE),
                ) { Text(stringResource(R.string.shopping_continue)) }
            }
        }
    }
}

@Composable
private fun ErrorDialog(
    message: String,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.shopping_error_title)) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.shopping_error_ok)) } },
    )
}

/** Fin des courses, version minimale : « 12 articles en 18 min » et la contribution. L'écran complet est A9. */
@Composable
fun ShoppingSummaryScreen(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val contribution =
        summary.storeName?.let { store ->
            when (val k = summary.knowledge) {
                RouteKnowledge.NoStore -> null
                RouteKnowledge.Unknown -> stringResource(R.string.shopping_summary_first, store)
                is RouteKnowledge.Learning -> stringResource(R.string.shopping_summary_known, store, k.percent)
                is RouteKnowledge.Learned -> stringResource(R.string.shopping_summary_known, store, k.percent)
            }
        }
    Scaffold(modifier = modifier) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                pluralStringResource(R.plurals.shopping_summary_articles, summary.checkedCount, summary.checkedCount),
                style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.testTag(TAG_SUMMARY),
            )
            Text(
                stringResource(R.string.shopping_summary_minutes, summary.minutes),
                style = MaterialTheme.typography.titleLarge,
            )
            contribution?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = onClose, modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_CLOSE)) {
                Text(stringResource(R.string.shopping_summary_close))
            }
        }
    }
}

private const val ANNOUNCEMENT_MS = 2_000L
private const val FADE_MS = 150
private const val STACK_FONT_SCALE = 1.5f

internal const val TAG_ITEMS = "shoppingItems"
internal const val TAG_HEADER = "shoppingHeader"
internal const val TAG_BASKET = "basket"
internal const val TAG_ENTRY = "shoppingEntry"
internal const val TAG_FINISH = "finish"
internal const val TAG_UNDO = "undo"
internal const val TAG_UNDO_BANNER = "undoBanner"
internal const val TAG_ANNOUNCEMENT = "reorderAnnouncement"
internal const val TAG_REMAINING_SHEET = "remainingSheet"
internal const val TAG_KEEP = "keepRemaining"
internal const val TAG_DROP = "dropRemaining"
internal const val TAG_CONTINUE = "continueShopping"
internal const val TAG_SUMMARY = "summaryCount"
internal const val TAG_CLOSE = "closeSummary"
