package fr.parcourses.feature.shopping

import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

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
internal fun ShoppingContent(
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
internal fun ReorderAnnouncementNode(
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
internal fun ShoppingList(
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
                NotFoundRow(row, { actions.onRestore(row) }, Modifier.rowAnimation(this, reduceMotion))
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

internal fun LazyListScope.rows(
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
            modifier = Modifier.rowAnimation(this, reduceMotion),
        )
        HorizontalDivider()
    }
}

/** Réordonnancement animé ; « réduire les animations » : plus de glissement, un fondu de 150 ms (#10 §8.2). */
internal fun Modifier.rowAnimation(
    scope: LazyItemScope,
    reduceMotion: Boolean,
): Modifier =
    with(scope) {
        if (reduceMotion) {
            animateItem(fadeInSpec = tween(FADE_MS), placementSpec = null, fadeOutSpec = tween(FADE_MS))
        } else {
            animateItem()
        }
    }

internal const val ANNOUNCEMENT_MS = 2_000L
internal const val FADE_MS = 150
internal const val STACK_FONT_SCALE = 1.5f

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
