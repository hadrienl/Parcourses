package fr.parcourses.feature.shopping

import android.os.Build
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay

/**
 * Mode courses. Avec un résumé, l'écran de fin prend la place le temps que la navigation le remplace par sa
 * propre entrée (`ShoppingSummaryRoute`). Les animations suivent l'échelle d'animation du système : « Supprimer les
 * animations » les rend instantanées.
 * [announce] : annonce polie à TalkBack (voir [rememberAnnouncer]) ; `null` : région polie sur le titre.
 */
@Composable
fun ShoppingScreen(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    modifier: Modifier = Modifier,
    announce: ((String) -> Unit)? = rememberAnnouncer(),
) {
    val summary = state.summary
    if (summary != null) {
        // Repli le temps que la navigation affiche l'entrée du résumé : c'est elle qui s'annonce, pas ce repli.
        ShoppingSummaryScreen(summary, actions.onClose, modifier, announcesPane = false)
    } else {
        ShoppingContent(state, input, actions, announce, modifier)
    }
}

/**
 * Annonce polie sans nœud dédié : `announceForAccessibility` jusqu'à l'API 35. Elle est dépréciée à partir de
 * l'API 36, qui recommande une région « live » : on rend alors `null` et l'écran pose une région polie sur son titre,
 * toujours affiché, le temps de l'annonce. Aucun des deux ne déplace le focus de TalkBack.
 */
@Composable
fun rememberAnnouncer(): ((String) -> Unit)? {
    val view = LocalView.current
    return remember(view) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) {
            { text: String ->
                @Suppress("DEPRECATION") // Déprécié à partir de l'API 36 seulement, jamais appelé au-delà.
                view.announceForAccessibility(text)
            }
        } else {
            null
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ShoppingContent(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    announce: ((String) -> Unit)?,
    modifier: Modifier,
) {
    var showsRemaining by rememberSaveable { mutableStateOf(false) }
    val reorderText = state.reorder?.let { stringResource(R.string.shopping_reordered, it.next) }
    ReorderAnnouncer(state.reorder, reorderText, announce, actions.onAnnouncementShown)
    // Région polie (API 36+) : seulement pendant l'annonce, sinon chaque changement du titre serait relu.
    val liveTitle = reorderText.takeIf { announce == null }
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        state.name,
                        modifier =
                            Modifier.testTag(TAG_TITLE).semantics {
                                if (liveTitle != null) {
                                    liveRegion = LiveRegionMode.Polite
                                    stateDescription = liveTitle
                                }
                            },
                    )
                },
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
            ShoppingList(state, actions)
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

/** Annonce le réordonnancement une fois, puis l'oublie après [ANNOUNCEMENT_MS]. */
@Composable
internal fun ReorderAnnouncer(
    reorder: ReorderAnnouncement?,
    text: String?,
    announce: ((String) -> Unit)?,
    onShown: (Int) -> Unit,
) {
    val seq = reorder?.seq ?: return
    val currentAnnounce by rememberUpdatedState(announce)
    val currentShown by rememberUpdatedState(onShown)
    LaunchedEffect(seq) {
        text?.let { currentAnnounce?.invoke(it) }
        delay(ANNOUNCEMENT_MS)
        currentShown(seq)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ShoppingList(
    state: ShoppingUiState,
    actions: ShoppingActions,
) {
    val listState = rememberLazyListState()
    var basketExpanded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(listState) { snapshotFlow { listState.isScrollInProgress }.collect(actions.onScrolling) }
    LazyColumn(Modifier.fillMaxSize().testTag(TAG_ITEMS), state = listState) {
        item(key = "header", contentType = "header") { Header(state) }
        if (state.groupsByAisle) {
            state.sections.forEach { section ->
                stickyHeader(key = "aisle-${section.aisleId}", contentType = "aisle") { AisleHeader(section) }
                rows(section.rows, state, actions)
            }
        } else {
            rows(state.toBuy, state, actions)
        }
        if (state.notFound.isNotEmpty()) {
            item(key = "not-found-header", contentType = "title") {
                SectionTitle(stringResource(R.string.shopping_not_found_title))
            }
            items(state.notFound, key = { it.id }, contentType = { "not-found" }) { row ->
                NotFoundRow(row, { actions.onRestore(row) }, Modifier.animateItem())
                HorizontalDivider()
            }
        }
        if (state.basket.isNotEmpty()) {
            item(key = "basket-header", contentType = "basket") {
                BasketHeader(state.basket.size, basketExpanded) { basketExpanded = !basketExpanded }
            }
            if (basketExpanded) rows(state.basket, state, actions)
        }
    }
}

internal fun LazyListScope.rows(
    rows: List<ShoppingRow>,
    state: ShoppingUiState,
    actions: ShoppingActions,
) {
    items(rows, key = { it.id }, contentType = { "row" }) { row ->
        ItemRow(
            row = row,
            highlighted = state.highlightedItemId == row.id,
            actions = actions,
            modifier = Modifier.animateItem(),
        )
        HorizontalDivider()
    }
}

internal const val ANNOUNCEMENT_MS = 2_000L
internal const val STACK_FONT_SCALE = 1.5f

internal const val TAG_ITEMS = "shoppingItems"
internal const val TAG_HEADER = "shoppingHeader"
internal const val TAG_BASKET = "basket"
internal const val TAG_ENTRY = "shoppingEntry"
internal const val TAG_FINISH = "finish"
internal const val TAG_UNDO = "undo"
internal const val TAG_UNDO_BANNER = "undoBanner"
internal const val TAG_TITLE = "shoppingTitle"
internal const val TAG_REMAINING_SHEET = "remainingSheet"
internal const val TAG_KEEP = "keepRemaining"
internal const val TAG_DROP = "dropRemaining"
internal const val TAG_CONTINUE = "continueShopping"
internal const val TAG_SUMMARY = "summaryCount"
internal const val TAG_CLOSE = "closeSummary"
internal const val TAG_SUMMARY_HEADLINE = "summaryHeadline"
internal const val TAG_CONTRIBUTION = "contribution"
