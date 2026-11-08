package fr.parcourses.feature.shopping

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.categorizer.ORGANIC_CATEGORY_ID
import fr.parcourses.core.categorizer.effectiveCategory
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.CategoryRepository
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.StoreRepository
import fr.parcourses.core.data.repository.VisitRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortOutput
import fr.parcourses.core.model.SortParams
import fr.parcourses.core.model.SortStart
import fr.parcourses.core.sorting.sortItems
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Ce dont le mode courses a besoin pour lire et écrire. */
class ShoppingDependencies(
    val lists: ListRepository,
    val visits: VisitRepository,
    val stores: StoreRepository,
    val categories: CategoryRepository,
    val analyzer: EntryAnalyzer,
    val cache: GraphSnapshotCache,
)

/**
 * Mode courses (#9 §6.3, port de `ShoppingSession` d'iOS) : ordre affiché, coches, introuvables, ajouts,
 * annulation et fin. Tout s'écrit d'abord en local : ni le réseau ni la session ne sont jamais attendus pour cocher.
 *
 * Fil d'exécution : tout se passe sur le fil principal (`viewModelScope`) ; les écritures et les lectures sont
 * sérialisées par un verrou, le tri seul s'exécute sur [computation]. [storeId] à `null` : sans magasin, ordre
 * générique, ni visite ni instantané.
 *
 * Les écritures de coche, de décoche, d'annulation et de fin ne sont jamais interrompues par la sortie de l'écran
 * (`NonCancellable`). Le résumé de fin quitte ce modèle par `ShoppingRoute(onFinished)` : la navigation le garde dans
 * sa pile, qui survit à la mort du processus.
 */
@OptIn(ExperimentalCoroutinesApi::class)
@Suppress("TooManyFunctions", "LargeClass") // Machine d'états unique : la scinder ferait voyager l'état partagé.
class ShoppingViewModel(
    listId: String,
    private val storeId: String?,
    private val deps: ShoppingDependencies,
    remaps: Flow<IdentifierRemap> = emptyFlow(),
    private val timings: ShoppingTimings = ShoppingTimings(),
    private val now: () -> Instant = { Clock.System.now() },
    private val computation: CoroutineDispatcher = Dispatchers.Default,
) : ViewModel() {
    private val _uiState = MutableStateFlow(ShoppingUiState())
    val uiState: StateFlow<ShoppingUiState> = _uiState.asStateFlow()

    /** Champ « Ajouter un article », hissé ici pour survivre à la rotation. */
    val input = TextFieldState()

    private val lock = Mutex()
    private val listIdFlow = MutableStateFlow(listId)
    private val listId: String get() = listIdFlow.value

    private var visitId: String? = null
    private var started = false
    private var startedAt: Instant = Instant.DISTANT_PAST
    private var expiredAt: Instant? = null

    /** Visite close d'office (45 min) et gardée parce qu'elle avait des coches. */
    private var expiredVisitId: String? = null
    private var name = ""
    private var storeName: String? = null
    private var storeOrganicAisle = false
    private var categoryLabels: Map<String, String> = emptyMap()
    private var sortCategories: List<SortCategory> = emptyList()
    private var current: LoadedSnapshot? = null
    private var mode = SortOutput.Mode.Fallback
    private var knowledge: RouteKnowledge = RouteKnowledge.NoStore

    /** Arrivé pendant la visite : s'applique à la coche suivante, jamais spontanément (#9 §5.4). */
    private var pendingSnapshot: LoadedSnapshot? = null

    /** Même règle pour le rayon bio venu du serveur : la liste ne bouge pas d'elle-même. */
    private var pendingOrganicAisle: Boolean? = null

    private var toBuy: List<ShoppingRow> = emptyList()
    private var basket: List<ShoppingRow> = emptyList()
    private var notFound: List<ShoppingRow> = emptyList()
    private var undo: ShoppingUndo? = null
    private var highlighted: String? = null
    private var expired = false
    private var summary: ShoppingSummary? = null
    private var reorder: ReorderAnnouncement? = null
    private var errorMessage: String? = null
    private var announcements = 0

    /** Ordre que la personne a vu au dernier tri : seul un changement de place entre articles déjà vus s'annonce. */
    private var settledOrder: List<String> = emptyList()

    /** Lignes cochées qui restent à leur place jusqu'au prochain tri (600 ms). */
    private val settlingIds = mutableSetOf<String>()
    private var isScrolling = false
    private var isEditing = false
    private var hasUnsettledChange = false

    /**
     * Articles tels que la dernière lecture les a vus, réduits à ce que l'écran montre : une émission qui ne change
     * que l'état d'envoi (`syncState`, `updatedAt`) n'est pas un changement extérieur.
     */
    private var lastItems: List<ItemView> = emptyList()

    /** Durée d'affichage de « Annuler », éventuellement allongée par les réglages d'accessibilité. */
    private var undoDuration: Duration = timings.undo
    private var isSwiping = false

    /** Rechargements dus à un changement venu d'ailleurs : lu par les tests seulement. */
    internal var externalReloads = 0
        private set

    private var settleJob: Job? = null
    private var undoJob: Job? = null
    private var highlightJob: Job? = null
    private var refreshJob: Job? = null

    init {
        viewModelScope.launch { remaps.collect { remap -> lock.withLock { apply(remap) } } }
    }

    // region Ouverture

    /**
     * Ouvre la visite (ou reprend celle qui est déjà ouverte pour cette liste et ce magasin), une seule fois.
     * La visite ne reste qu'en local jusqu'à la première coche.
     */
    fun start() {
        if (started) return
        started = true
        viewModelScope.launch { lock.withLock { open() } }
    }

    private suspend fun open() {
        // Reprise d'une visite encore active (même liste, même magasin) : son début compte, avant tout tri.
        val resumed = storeId?.let { resumableVisit(it) }
        visitId = resumed?.id
        startedAt = resumed?.startedAt ?: now()
        prepare()
        if (storeId != null && resumed == null) {
            perform {
                // `listWasSorted` : le mode du début de visite, celui que la personne a réellement suivi (#9 §6.3).
                // Une visite restée ouverte trop longtemps est close à sa dernière coche, puis une neuve commence.
                val visit =
                    deps.visits.startVisit(
                        storeId,
                        listId,
                        mode == SortOutput.Mode.Learned,
                        startedAt,
                        staleAfter = timings.expiry,
                    )
                visitId = visit.id
                startedAt = visit.startedAt
            }
        }
        publish(loaded = true)
        observeExternalChanges()
    }

    /** Visite ouverte pour cette liste et ce magasin, active il y a moins de 45 min. */
    private suspend fun resumableVisit(storeId: String) =
        attempt {
            deps.visits.openVisit()?.takeIf { visit ->
                val last = deps.visits.lastActivity(visit.id) ?: visit.startedAt
                visit.storeId == storeId && visit.listId == listId && now() - last < timings.expiry
            }
        }

    private suspend fun prepare() {
        perform {
            name =
                deps.lists
                    .list(listId)
                    ?.name
                    .orEmpty()
            val categories = deps.categories.categories()
            sortCategories = categories.map { SortCategory(it.id, it.rank.toLong()) }
            categoryLabels = categories.associate { it.id to it.label }
            storeId?.let { id -> deps.stores.store(id) }?.let {
                storeName = it.name
                storeOrganicAisle = it.organicAisle
            }
        }
        if (storeId != null) {
            current = attempt { deps.cache.cached(storeId) }
            preloadSnapshot(storeId)
        }
        refreshKnowledge()
        reloadRows()
        sortNow(previous = null)
    }

    /** Attend le serveur au plus `preload`. Au-delà, la réponse attend la première coche dans [pendingSnapshot]. */
    private suspend fun preloadSnapshot(storeId: String) {
        val finished = CompletableDeferred<Unit>()
        refreshJob =
            viewModelScope.launch {
                try {
                    // Le cache peut dater : un magasin d'avant la migration du rayon bio y est « sans rayon bio ».
                    attempt { deps.cache.gateway?.storeOrganicAisle(Uuid.parse(storeId)) }?.let { organic ->
                        attempt { deps.stores.updateOrganicAisle(storeId, organic) }
                        pendingOrganicAisle = organic
                    }
                    pendingSnapshot = attempt { deps.cache.refresh(storeId) }
                } finally {
                    finished.complete(Unit)
                }
            }
        withTimeoutOrNull(timings.preload) { finished.await() }
        adoptPendingSnapshot()
    }

    private fun adoptPendingSnapshot() {
        pendingOrganicAisle?.let {
            storeOrganicAisle = it
            pendingOrganicAisle = null
        }
        val snapshot = pendingSnapshot ?: return
        current = snapshot
        pendingSnapshot = null
        refreshKnowledge()
    }

    private fun refreshKnowledge() {
        val snapshot = current
        knowledge =
            when {
                storeId == null -> {
                    RouteKnowledge.NoStore
                }

                snapshot == null || snapshot.snapshot.confidenceQ <= 0 -> {
                    RouteKnowledge.Unknown
                }

                else -> {
                    val percent = (snapshot.snapshot.confidenceQ / PERCENT_DIVISOR).toInt()
                    if (snapshot.snapshot.confidenceQ >= snapshot.params.confThresholdQ) {
                        RouteKnowledge.Learned(percent)
                    } else {
                        RouteKnowledge.Learning(percent)
                    }
                }
            }
    }

    /** Les changements venus d'ailleurs (descente de synchro) : ceux que nos propres lectures n'ont pas vus. */
    private fun observeExternalChanges() {
        viewModelScope.launch {
            listIdFlow
                .flatMapLatest { deps.lists.observeItems(it) }
                .collect { items -> lock.withLock { if (items.map(::ItemView) != lastItems) syncDidChange() } }
        }
    }

    // endregion

    // region Actions

    fun toggle(row: ShoppingRow) = actDurably { if (row.isChecked) uncheck(row) else check(row) }

    private suspend fun check(row: ShoppingRow) {
        val index = toBuy.indexOfFirst { it.id == row.id }
        val item = item(row.id)
        // Double événement (double appui, balayage puis appui) : un article déjà coché ne l'est pas deux fois.
        if (item == null || index < 0 || item.checkedAt != null) return
        val date = now()
        var checkId: String? = null
        val succeeded =
            perform {
                val visit = visitId
                if (visit != null) {
                    checkId =
                        deps.visits
                            .checkItem(
                                visitId = visit,
                                itemId = row.id,
                                subject = subject(item),
                                checkedAt = date,
                                // Marge : l'envoi ne doit pas partir pendant que « Annuler » est encore affiché.
                                sendAfter = undoDuration + timings.sendMargin,
                            ).id
                } else {
                    deps.lists.setChecked(row.id, date, date)
                }
            }
        if (!succeeded) return
        // La ligne reste à sa place jusqu'au prochain tri : elle ne bouge jamais sous le doigt.
        settlingIds += row.id
        toBuy = toBuy.toMutableList().also { it[index] = row.copy(isChecked = true) }
        lastItems = attempt { deps.lists.items(listId) }?.map(::ItemView) ?: lastItems
        adoptPendingSnapshot()
        // Même origine que le `notBefore` de la coche : la bannière disparaît avant que la coche puisse partir.
        offerUndo(ShoppingUndo(ShoppingUndo.Kind.Check, row.id, row.label, checkId, index), until = date + undoDuration)
        scheduleSettle()
        publish()
    }

    /** Ce que désigne la coche : le produit, sinon la catégorie du classifieur, jamais le rayon bio (#28). */
    private fun subject(item: ListItemEntity): CheckSubject =
        item.productId?.let { CheckSubject.Product(it) }
            ?: if (item.categoryId == ORGANIC_CATEGORY_ID) {
                CheckSubject.Category(deps.analyzer.classify(item.label).first)
            } else {
                CheckSubject.Category(item.categoryId)
            }

    /**
     * Nouvel appui sur une ligne cochée. Une coche déjà partie reste au serveur, qui ne retient que la première de
     * chaque produit : seule la liste change alors.
     */
    private suspend fun uncheck(row: ShoppingRow) {
        val date = now()
        val succeeded =
            perform {
                val visit = visitId
                if (visit != null) {
                    val check = deps.visits.checks(visit).lastOrNull { it.itemId == row.id }
                    deps.visits.uncheckItem(row.id, check?.id, date)
                } else {
                    deps.lists.setChecked(row.id, null, date)
                }
            }
        if (!succeeded) return
        settlingIds -= row.id
        if (undo?.itemId == row.id) clearUndo()
        reloadRows()
        scheduleSettle()
        publish()
    }

    fun markNotFound(row: ShoppingRow) =
        actDurably {
            if (row.isChecked) return@actDurably
            val index = toBuy.indexOfFirst { it.id == row.id }.coerceAtLeast(0)
            val date = now()
            if (!perform { deps.lists.setNotFound(row.id, date) }) return@actDurably
            reloadRows()
            offerUndo(
                ShoppingUndo(ShoppingUndo.Kind.NotFound, row.id, row.label, null, index),
                until =
                    date + undoDuration,
            )
            scheduleSettle()
            publish()
        }

    /** Remet un article introuvable dans ce qu'il reste à acheter. */
    fun restore(row: ShoppingRow) =
        actDurably {
            if (!perform { deps.lists.setNotFound(row.id, null) }) return@actDurably
            reloadRows()
            scheduleSettle()
            publish()
        }

    /** Ajout en route : l'article prend sa place estimée sans déplacer les autres, le temps de la saisie. */
    fun submit() =
        actDurably {
            val entry = deps.analyzer.analyze(input.text.toString())
            if (entry.label.isEmpty()) return@actDurably
            var added: String? = null
            val succeeded =
                perform {
                    added =
                        deps.lists
                            .addItem(
                                listId,
                                entry.label,
                                entry.normalizedName,
                                entry.quantity,
                                null,
                                entry.categoryId,
                                now(),
                            ).id
                }
            val id = added
            if (!succeeded || id == null) return@actDurably
            input.clearText()
            // Lignes juste cochées comprises : elles gardent leur place.
            val previous = toBuy.map { it.id }
            reloadRows()
            val estimated = computeOrder(previous)
            val predecessors = estimated.takeWhile { it != id }.toSet()
            val order = previous.toMutableList()
            order.add(order.indexOfLast { it in predecessors } + 1, id)
            arrange(order)
            settledOrder = toBuy.filter { !it.isChecked }.map { it.id }
            highlight(id)
            publish()
        }

    fun performUndo() =
        actDurably {
            val action = undo ?: return@actDurably
            clearUndo()
            val date = now()
            val succeeded =
                perform {
                    when (action.kind) {
                        ShoppingUndo.Kind.Check -> {
                            if (action.checkId != null) {
                                deps.visits.uncheckItem(action.itemId, action.checkId, date)
                            } else {
                                deps.lists.setChecked(action.itemId, null, date)
                            }
                        }

                        ShoppingUndo.Kind.NotFound -> {
                            deps.lists.setNotFound(action.itemId, null)
                        }
                    }
                }
            if (!succeeded) return@actDurably
            settlingIds -= action.itemId
            // La ligne reprend sa place : l'annulation n'est pas un nouveau trajet.
            val order = toBuy.map { it.id }.filter { it != action.itemId }.toMutableList()
            order.add(minOf(action.index, order.size), action.itemId)
            reloadRows()
            arrange(order)
            settledOrder = toBuy.filter { !it.isChecked }.map { it.id }
            // Le tri attendu par une autre coche reste dû ; sinon l'annulation ne déclenche aucun trajet.
            if (settlingIds.isEmpty()) {
                settleJob?.cancel()
                hasUnsettledChange = false
            } else {
                scheduleSettle()
            }
            publish()
        }

    fun dismissError() {
        errorMessage = null
        publish()
    }

    /** L'annonce a été lue : elle ne reste pas dans l'arbre d'accessibilité. */
    fun announcementShown(seq: Int) {
        if (reorder?.seq == seq) {
            reorder = null
            publish()
        }
    }

    // endregion

    // region Tri

    fun setScrolling(value: Boolean) {
        isScrolling = value
        interactionChanged()
    }

    fun setEditing(value: Boolean) {
        isEditing = value
        interactionChanged()
    }

    /** Balayage horizontal en cours sur une ligne : la liste ne bouge pas sous le doigt. */
    fun setSwiping(value: Boolean) {
        isSwiping = value
        interactionChanged()
    }

    /**
     * Durée de « Annuler », allongée si l'accessibilité le recommande (`getRecommendedTimeoutMillis`). À fixer avant
     * la première coche : elle retient aussi l'envoi de la coche.
     */
    fun setUndoDuration(value: Duration) {
        undoDuration = maxOf(value, timings.undo)
    }

    /** Une interaction suspend un tri en attente ; le délai repart de zéro à sa fin. */
    private fun interactionChanged() {
        if (hasUnsettledChange) scheduleSettle()
    }

    /** Rien ne bouge pendant un défilement ou une saisie : le tri attend 600 ms d'inactivité (#6). */
    private fun scheduleSettle() {
        hasUnsettledChange = true
        settleJob?.cancel()
        settleJob = null
        // Un clavier resté ouvert sans texte ne doit pas figer la liste : seule une saisie en cours suspend le tri.
        val typing = isEditing && input.text.isNotEmpty()
        if (isScrolling || isSwiping || typing) return
        settleJob =
            viewModelScope.launch {
                delay(timings.settle)
                lock.withLock { sortNow(toBuy.filter { !it.isChecked }.map { it.id }) }
            }
    }

    private suspend fun sortNow(previous: List<String>?) {
        val order = computeOrder(previous)
        hasUnsettledChange = false
        settlingIds.clear()
        reloadRows()
        arrange(order)
        if (previous != null) announceReorder(settledOrder)
        settledOrder = toBuy.filter { !it.isChecked }.map { it.id }
        publish()
    }

    /** Annonce polie quand des articles déjà affichés ont changé de place entre eux. */
    private fun announceReorder(before: List<String>) {
        val after = toBuy.filter { !it.isChecked }
        val afterIds = after.map { it.id }
        val common = before.toSet().intersect(afterIds.toSet())
        if (before.filter { it in common } == afterIds.filter { it in common }) return
        after.firstOrNull()?.let { reorder = ReorderAnnouncement(++announcements, it.label) }
    }

    /** Calcul hors du fil principal (#9 §3.3). Une entrée refusée laisse l'ordre actuel : la coche n'attend jamais. */
    private suspend fun computeOrder(previous: List<String>?): List<String> {
        val items = attempt { remainingItems() }.orEmpty()
        val sortInput = sortInput(items, previous)
        return try {
            val output = withContext(computation) { sortItems(sortInput) }
            mode = output.mode
            output.order
        } catch (ignored: IllegalArgumentException) {
            // Entrée refusée (identifiant invalide, doublon) : on garde l'ordre affiché.
            mode = SortOutput.Mode.Fallback
            previous ?: items.map { it.id }
        }
    }

    /** Rayon effectif d'un article pour ce magasin (#28) : celui du tri et des titres de section. */
    private fun aisle(item: ListItemEntity): String =
        effectiveCategory(item.categoryId, deps.analyzer.classify(item.label).second, storeOrganicAisle)

    private suspend fun sortInput(
        items: List<ListItemEntity>,
        previous: List<String>?,
    ): SortInput =
        SortInput(
            params = current?.params ?: SortParams.Default,
            categories = sortCategories,
            snapshot = current?.snapshot,
            items =
                items.map {
                    // Le rayon bio n'existe que pour le tri, et seulement si le magasin en a un (#28).
                    SortItem(it.id, it.productId, aisle(it), it.normalizedName)
                },
            start = resolvedStart(),
            previousOrder = previous,
        )

    /** Dernier article coché de cette visite ayant un produit, sinon l'entrée du magasin. */
    private suspend fun resolvedStart(): SortStart {
        val last =
            attempt { deps.lists.items(listId) }
                .orEmpty()
                .filter { it.productId != null && (it.checkedAt ?: Instant.DISTANT_PAST) >= startedAt }
                .maxByOrNull { it.checkedAt ?: Instant.DISTANT_PAST }
        return last?.productId?.let { SortStart.Product(it) } ?: SortStart.Entry
    }

    private suspend fun remainingItems(): List<ListItemEntity> =
        deps.lists.items(listId).filter { it.checkedAt == null && it.notFoundAt == null }

    /** Applique un ordre aux lignes déjà lues. Ce qui n'y figure pas garde sa place relative, à la fin. */
    private fun arrange(order: List<String>) {
        toBuy = ordered(toBuy, order)
    }

    private fun ordered(
        rows: List<ShoppingRow>,
        order: List<String>,
    ): List<ShoppingRow> {
        val rank = HashMap<String, Int>()
        order.forEachIndexed { index, id -> rank.putIfAbsent(id, index) }
        return rows
            .withIndex()
            .sortedBy { (offset, row) -> rank[row.id] ?: (order.size + offset) }
            .map { it.value }
    }

    /** Relit la liste en gardant l'ordre affiché. Une ligne juste cochée ne passe au panier qu'au tri suivant. */
    private suspend fun reloadRows() {
        val items = attempt { deps.lists.items(listId) }.orEmpty()
        lastItems = items.map(::ItemView)
        val rows = items.map { it to ShoppingRow(it.id, it.label, it.quantity, it.checkedAt != null, aisle(it)) }
        val settling = settlingIds
        toBuy =
            ordered(
                rows
                    .filter { (item, row) -> row.id in settling || (item.checkedAt == null && item.notFoundAt == null) }
                    .map { it.second },
                toBuy.map { it.id },
            )
        basket =
            rows
                .filter { (item, row) -> item.checkedAt != null && row.id !in settling }
                .sortedByDescending { it.first.checkedAt }
                .map { it.second }
        notFound = rows.filter { (item, _) -> item.checkedAt == null && item.notFoundAt != null }.map { it.second }
    }

    /** Après une descente : les changements venus d'ailleurs, sans toucher à une ligne en attente. */
    private suspend fun syncDidChange() {
        if (hasUnsettledChange || summary != null || expired) return
        externalReloads++
        reloadRows()
        scheduleSettle()
        publish()
    }

    // endregion

    // region Annulation et repère

    /** Propose d'annuler [action] jusqu'à [until]. */
    private fun offerUndo(
        action: ShoppingUndo,
        until: Instant,
    ) {
        undoJob?.cancel()
        undo = action
        undoJob =
            viewModelScope.launch {
                delay((until - now()).coerceAtLeast(ZERO))
                lock.withLock {
                    undo = null
                    publish()
                }
            }
    }

    private fun clearUndo() {
        undoJob?.cancel()
        undo = null
    }

    private fun highlight(id: String) {
        highlighted = id
        highlightJob?.cancel()
        highlightJob =
            viewModelScope.launch {
                delay(timings.highlight)
                lock.withLock {
                    highlighted = null
                    publish()
                }
            }
    }

    // endregion

    // region Fin

    /**
     * Au retour au premier plan : 45 min sans coche terminent la visite. La date de fin est celle de la dernière
     * coche, pas celle du retour, qui allongerait la visite de tout le temps passé ailleurs.
     */
    fun foregrounded() = act { expireIfIdle() }

    private suspend fun expireIfIdle() {
        val visit = visitId
        if (visit == null || expired || summary != null) return
        val lastActivity =
            attempt {
                deps.visits
                    .checks(visit)
                    .lastOrNull()
                    ?.checkedAt
            } ?: startedAt
        val idleLongEnough = now() - lastActivity >= timings.expiry
        var kept = false
        if (!idleLongEnough || !perform { kept = deps.visits.closeVisit(visit, lastActivity) }) return
        expiredVisitId = visit.takeIf { kept }
        visitId = null
        expiredAt = lastActivity
        expired = true
        settlingIds.clear()
        clearUndo()
        reloadRows()
        publish()
        if (toBuy.none { !it.isChecked } && notFound.isEmpty()) finishNow(keepRemaining = true)
    }

    /**
     * Termine les courses. [keepRemaining] : les articles restants attendent la prochaine fois, sinon ils quittent
     * la liste.
     */
    fun finish(keepRemaining: Boolean) = actDurably { finishNow(keepRemaining) }

    private suspend fun finishNow(keepRemaining: Boolean) {
        val date = now()
        settleJob?.cancel()
        refreshJob?.cancel()
        settlingIds.clear()
        clearUndo()
        reloadRows()
        val closing = visitId
        // `closeVisit` supprime une visite sans coche : le résumé n'a alors aucune visite à désigner.
        var closed: String? = null
        val succeeded =
            perform {
                if (keepRemaining) {
                    notFound.forEach { deps.lists.setNotFound(it.id, null) }
                } else {
                    (toBuy + notFound).forEach { deps.lists.deleteItem(it.id, date) }
                }
                if (closing != null && deps.visits.closeVisit(closing, date)) closed = closing
            }
        if (!succeeded) return
        visitId = null
        val checked =
            deps.lists.items(listId).count { (it.checkedAt ?: Instant.DISTANT_PAST) >= startedAt }
        val end = expiredAt ?: date
        val minutes = ((end - startedAt).inWholeSeconds / SECONDS_PER_MINUTE.toDouble()).roundToInt()
        summary =
            ShoppingSummary(
                checkedCount = checked,
                minutes = maxOf(1, minutes),
                storeName = storeName,
                knowledge = knowledge,
                // Visite expirée : déjà close par `expireIfIdle`, elle existe encore si elle avait des coches.
                visitId = closed ?: expiredVisitId,
            )
        reloadRows()
        publish()
    }

    // endregion

    // region Outils

    /** Les données ont changé d'identifiants (perte de session) : la visite continue, tout le reste suit. */
    private fun apply(remap: IdentifierRemap) {
        listIdFlow.value = remap[listId]
        visitId = visitId?.let { remap[it] }
        val renamed = settlingIds.map { remap[it] }
        settlingIds.clear()
        settlingIds += renamed
        highlighted = highlighted?.let { remap[it] }
        undo = undo?.let { it.copy(itemId = remap[it.itemId], checkId = it.checkId?.let(remap::get)) }
        expiredVisitId = expiredVisitId?.let { remap[it] }

        fun List<ShoppingRow>.remapped() = map { it.copy(id = remap[it.id]) }
        toBuy = toBuy.remapped()
        basket = basket.remapped()
        notFound = notFound.remapped()
        if (hasUnsettledChange) scheduleSettle()
        publish()
    }

    private suspend fun item(id: String): ListItemEntity? =
        attempt { deps.lists.items(listId) }?.firstOrNull {
            it.id ==
                id
        }

    /** Lance une action sérialisée avec les autres. */
    private fun act(block: suspend () -> Unit) {
        viewModelScope.launch { lock.withLock { block() } }
    }

    /**
     * Action qui écrit ce que la personne a fait (coche, introuvable, ajout, annulation, fin) : elle démarre même si
     * l'écran vient d'être quitté et n'est jamais interrompue, sinon un Retour juste après l'appui perdrait la coche.
     */
    private fun actDurably(block: suspend () -> Unit) {
        viewModelScope.launch(
            start = CoroutineStart.ATOMIC,
        ) { withContext(NonCancellable) { lock.withLock { block() } } }
    }

    // Une écriture qui échoue est montrée à l'utilisateur ; l'annulation est relancée. Une écriture commencée va au
    // bout, même si l'écran se ferme entre-temps.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun perform(work: suspend () -> Unit): Boolean =
        try {
            withContext(NonCancellable) { work() }
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorMessage = e.message ?: e.javaClass.simpleName
            publish()
            false
        }

    // Une lecture qui échoue donne « rien » : l'écran garde ce qu'il montre.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun <T> attempt(work: suspend () -> T): T? =
        try {
            work()
        } catch (e: CancellationException) {
            throw e
        } catch (ignored: Exception) {
            null
        }

    private fun publish(loaded: Boolean = _uiState.value.isLoaded) {
        val groups = mode != SortOutput.Mode.Learned
        _uiState.update {
            ShoppingUiState(
                isLoaded = loaded,
                name = name,
                storeName = storeName,
                toBuy = toBuy,
                basket = basket,
                notFound = notFound,
                sections = if (groups) sections() else emptyList(),
                groupsByAisle = groups,
                knowledge = knowledge,
                undo = undo,
                highlightedItemId = highlighted,
                expired = expired,
                summary = summary,
                reorder = reorder,
                errorMessage = errorMessage,
            )
        }
    }

    /**
     * Rayons dans l'ordre des rangs de catégories, articles dans l'ordre affiché. Une ligne juste cochée reste dans
     * son rayon jusqu'au tri suivant, comme dans `toBuy`.
     */
    private fun sections(): List<ShoppingSection> {
        val indices = HashMap<String, Int>()
        sortCategories
            .sortedWith(compareBy<SortCategory> { it.rank }.thenBy { it.id })
            .forEachIndexed { index, category -> indices.putIfAbsent(category.id, index) }
        val fallback = indices[CategoryClassifier.OTHER_CATEGORY_ID] ?: maxOf(0, sortCategories.size - 1)
        val grouped = toBuy.groupBy { it.aisleId }
        return grouped.keys
            .sortedWith(compareBy<String> { indices[it] ?: fallback }.thenBy { it })
            .map { aisle -> ShoppingSection(aisle, categoryLabels[aisle] ?: aisle, grouped.getValue(aisle)) }
    }

    // endregion

    private companion object {
        /** `confidence_q` est en millièmes : on affiche des pourcents entiers. */
        const val PERCENT_DIVISOR = 10L
        const val SECONDS_PER_MINUTE = 60
    }
}

/** Ce que l'écran montre d'un article : seuls ces champs comptent pour reconnaître un changement extérieur. */
private data class ItemView(
    val id: String,
    val label: String,
    val quantity: String?,
    val productId: String?,
    val categoryId: String,
    val normalizedName: String,
    val checkedAt: Instant?,
    val notFoundAt: Instant?,
) {
    constructor(item: ListItemEntity) : this(
        item.id,
        item.label,
        item.quantity,
        item.productId,
        item.categoryId,
        item.normalizedName,
        item.checkedAt,
        item.notFoundAt,
    )
}
