package fr.parcourses.feature.shopping

import android.os.Build
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyItemScope
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import fr.parcourses.core.designsystem.Bead
import fr.parcourses.core.designsystem.OsmAttribution
import fr.parcourses.core.designsystem.ThreadPiece
import fr.parcourses.core.designsystem.ThreadSegment
import fr.parcourses.core.designsystem.ThreadStyle
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketMotion
import fr.parcourses.core.designsystem.TicketSheet
import fr.parcourses.core.designsystem.threadSegments
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
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.desk),
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
                onFinish = { onFinishTapped(state, askRemaining = { showsRemaining = true }, actions.onFinish) },
            )
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
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

/**
 * « Terminer » : la question « garder ou retirer » s'il reste des articles, sinon la fin. Rien avant la fin du
 * chargement : rien n'est encore compté, la question ne serait pas posée (#54).
 */
private fun onFinishTapped(
    state: ShoppingUiState,
    askRemaining: () -> Unit,
    finish: (keepRemaining: Boolean) -> Unit,
) {
    when {
        !state.isLoaded -> Unit
        state.remainingCount > 0 -> askRemaining()
        else -> finish(true)
    }
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

/** Un élément de la partie « à prendre » du ticket : un titre de rayon ou un article, dans l'ordre du fil. */
private sealed interface Stop {
    data class Aisle(
        val section: ShoppingSection,
    ) : Stop

    data class Item(
        val row: ShoppingRow,
    ) : Stop
}

/** Arrêts du fil : un titre par section puis ses articles ; sans section, les articles seuls. */
private fun stops(state: ShoppingUiState): List<Stop> =
    if (state.sections.isEmpty()) {
        state.toBuy.map(Stop::Item)
    } else {
        state.sections.flatMap { section -> listOf(Stop.Aisle(section)) + section.rows.map(Stop::Item) }
    }

/** Ce qu'il faut pour dessiner le fil le long de la partie « à prendre ». */
private class ThreadView(
    val stops: List<Stop>,
    val style: ThreadStyle,
    val risen: Set<String>,
    val reduced: Boolean,
) {
    /** Position de l'article suivant, le premier non coché ; la fin quand tout est pris. */
    val next: Int = stops.indexOfFirst { it is Stop.Item && !it.row.isChecked }.let { if (it < 0) stops.size else it }
    val segments = threadSegments(stops.size, next)

    fun bead(
        index: Int,
        row: ShoppingRow,
    ): Bead =
        when {
            row.isChecked -> Bead.Checked
            index == next -> Bead.Next
            else -> Bead.Idle
        }
}

/**
 * La liste du ticket. Le fil relie les rayons et les articles dans l'ordre du trajet ; il est parcouru jusqu'à la perle
 * de l'article suivant (le premier non coché). Trajet appris : fil plein ; sinon, la partie à venir est pointillée.
 * En mouvement réduit, rien ne glisse : les lignes changent de place d'un coup.
 */
@Composable
internal fun ShoppingList(
    state: ShoppingUiState,
    actions: ShoppingActions,
) {
    val listState = rememberLazyListState()
    var basketExpanded by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(listState) { snapshotFlow { listState.isScrollInProgress }.collect(actions.onScrolling) }
    // L'ordre réellement affiché fait foi (un instantané refusé retombe dans l'ordre générique), pas la confiance.
    val learned = !state.groupsByAisle
    val view =
        ThreadView(
            stops = stops(state),
            style = if (learned) ThreadStyle.Solid else ThreadStyle.Dashed,
            risen = rememberRisenRuns(state.sections, learned),
            reduced = Ticket.accessibility.reducedMotion,
        )
    LazyColumn(
        Modifier.fillMaxSize().testTag(TAG_ITEMS),
        state = listState,
        contentPadding = PaddingValues(bottom = TicketDimens.spaceL),
    ) {
        item(key = "header", contentType = "header") { Header(state) }
        toBuy(view, state.highlightedItemId, actions)
        notFound(state.notFound, view.reduced, actions)
        if (state.basket.isNotEmpty()) {
            item(key = "basket-header", contentType = "basket") {
                BasketHeader(state.basket.size, basketExpanded) { basketExpanded = !basketExpanded }
            }
            if (basketExpanded) basket(state.basket, view, actions)
        }
        // Magasins d'OpenStreetMap (ODbL) : mention en pied de ticket, sans gêner la lecture de la liste.
        if (state.storeName != null) {
            item(key = "attribution", contentType = "attribution") {
                OsmAttribution(Modifier.padding(top = TicketDimens.spaceL))
            }
        }
    }
}

private fun LazyListScope.toBuy(
    view: ThreadView,
    highlightedItemId: String?,
    actions: ShoppingActions,
) {
    view.stops.forEachIndexed { index, stop ->
        val (top, bottom) = view.segments[index]
        when (stop) {
            is Stop.Aisle -> {
                item(key = "aisle-${stop.section.id}", contentType = "aisle") {
                    AisleHeader(
                        section = stop.section,
                        piece = ThreadPiece(top, bottom),
                        style = view.style,
                        risen = stop.section.id in view.risen,
                        modifier = Modifier.ticketMotion(this, view.reduced),
                    )
                }
            }

            is Stop.Item -> {
                val row = stop.row
                val look =
                    RowLook(
                        piece = ThreadPiece(top, bottom, view.bead(index, row)),
                        style = view.style,
                        isNext = index == view.next,
                        highlighted = highlightedItemId == row.id,
                    )
                item(key = row.id, contentType = "row") {
                    ItemRow(row, look, actions, Modifier.ticketMotion(this, view.reduced))
                }
            }
        }
    }
}

private fun LazyListScope.notFound(
    rows: List<ShoppingRow>,
    reduced: Boolean,
    actions: ShoppingActions,
) {
    if (rows.isEmpty()) return
    item(key = "not-found-header", contentType = "title") {
        SectionTitle(stringResource(R.string.shopping_not_found_title))
    }
    items(rows, key = { it.id }, contentType = { "not-found" }) { row ->
        NotFoundRow(row, { actions.onRestore(row) }, Modifier.ticketMotion(this, reduced))
    }
}

/** Le panier, déplié : des perles pleines, hors du fil. */
private fun LazyListScope.basket(
    rows: List<ShoppingRow>,
    view: ThreadView,
    actions: ShoppingActions,
) {
    val look = RowLook(ThreadPiece(ThreadSegment.None, ThreadSegment.None, Bead.Checked), view.style)
    items(rows, key = { it.id }, contentType = { "row" }) { row ->
        ItemRow(row, look, actions, Modifier.ticketMotion(this, view.reduced))
    }
}

/** Glissement à ressort au réordonnancement (`motion.reorder`) ; ni glissement ni fondu en mouvement réduit. */
private fun Modifier.ticketMotion(
    scope: LazyItemScope,
    reduced: Boolean,
): Modifier =
    with(scope) {
        this@ticketMotion.animateItem(
            fadeInSpec = TicketMotion.fade(reduced),
            placementSpec = TicketMotion.reorder(reduced),
            fadeOutSpec = TicketMotion.fade(reduced),
        )
    }

internal const val ANNOUNCEMENT_MS = 2_000L

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
