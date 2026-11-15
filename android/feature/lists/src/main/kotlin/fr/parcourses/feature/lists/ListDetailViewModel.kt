package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.snapshotFlow
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.CategoryRepository
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.ProductRepository
import fr.parcourses.core.data.sharing.AccessChange
import fr.parcourses.core.data.sharing.RoleCapabilities
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.data.sharing.SharingMember
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.CategoryEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ListParticipantEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.model.ListRole
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlin.time.Clock
import kotlin.time.Instant

/**
 * Un article tel qu'affiché : une valeur, jamais l'entité Room. [authorMark] : initiale du dernier auteur s'il est un
 * autre membre d'une liste partagée (#87, vecteur `008`), [authorName] son prénom pour TalkBack.
 */
@Immutable
data class ItemRow(
    val id: String,
    val label: String,
    val quantity: String?,
    val categoryId: String,
    val normalizedName: String,
    val isChecked: Boolean,
    val authorMark: String? = null,
    val authorName: String? = null,
) {
    /** « Tomates, 2 », suivi par TalkBack de l'état coché ou non. */
    val accessibilityLabel: String get() = listOfNotNull(label, quantity).joinToString(", ")
}

/** Une autre personne de la liste, pour les pastilles : [label] affiché, [name] lu. */
@Immutable
data class MemberChip(
    val userId: String,
    val label: String,
    val name: String?,
    val role: ListRole,
)

/** Dernière modification d'un autre membre : « Modifiée par Léa · il y a 2 min ». */
@Immutable
data class LastChange(
    val authorName: String?,
    val at: Instant,
)

/**
 * Ce que le partage apporte à l'écran Liste (#87, lot 87.6) : personnes de la liste (base locale), réseau, messages
 * d'accès. Par défaut, une liste non partagée en ligne.
 */
class ListSharingSources(
    val participants: (String) -> Flow<List<ListParticipantEntity>> = { flowOf(emptyList()) },
    val isOnline: Flow<Boolean> = flowOf(true),
    val notices: Flow<List<AccessChange>> = flowOf(emptyList()),
    val acknowledge: (AccessChange) -> Unit = {},
)

/** Partage vu par l'écran Liste. */
@Immutable
data class ListSharingUi(
    val role: ListRole = ListRole.Owner,
    /** Les autres personnes (jamais moi), propriétaire d'abord. */
    val others: List<MemberChip> = emptyList(),
    val ownerName: String? = null,
    val lastChange: LastChange? = null,
    val isOffline: Boolean = false,
    /** Message d'accès de cette liste (lecture seule, retrait), à acquitter. */
    val notice: AccessChange? = null,
) {
    val isShared: Boolean get() = others.isNotEmpty()
    val capabilities: RoleCapabilities get() = SharingDecisions.roleCapabilities(role)
}

/** Articles d'un même rayon. */
@Immutable
data class ItemSection(
    val categoryId: String,
    val title: String,
    val items: List<ItemRow>,
)

/** Entrées du partage, lues ensemble. */
private data class SharingInputs(
    val role: ListRole,
    val people: List<ListParticipantEntity>,
    val online: Boolean,
    val notice: AccessChange?,
)

/** Marques d'auteur d'une liste (vecteur `008`) : seulement si elle est partagée, jamais pour moi. */
private class Authors(
    people: List<ListParticipantEntity>,
) {
    private val me = people.firstOrNull { it.isMe }?.userId.orEmpty()
    private val shared = people.any { !it.isMe }
    private val members = people.map { SharingMember(it.userId, it.displayName) }
    private val names = people.associate { it.userId to it.displayName }

    fun mark(updatedBy: String?): String? = SharingDecisions.itemAuthorMark(updatedBy, me, shared, members)

    fun name(updatedBy: String?): String? = updatedBy?.let(names::get)
}

/** Libellés des pastilles : initiale, deux lettres quand deux personnes ont la même. */
internal fun avatarLabelsOf(names: List<String?>): List<String> =
    fr.parcourses.core.designsystem.avatarLabels(names, SharingDecisions::memberInitial)

@Immutable
data class ListDetailUiState(
    val name: String = "",
    val sections: List<ItemSection> = emptyList(),
    val suggestions: List<ItemSuggestion> = emptyList(),
    /** Faux jusqu'à la première lecture : évite d'afficher « Liste vide » avant qu'elle soit faite. */
    val isLoaded: Boolean = false,
    /** Liste inconnue ou supprimée. */
    val isMissing: Boolean = false,
    val errorDetail: String? = null,
    val sharing: ListSharingUi = ListSharingUi(),
) {
    val isEmpty: Boolean get() = sections.isEmpty()
}

/**
 * Modèle de l'écran Liste. Il suit la liste si son identifiant change (reprise de compte, [remaps]) sans perdre la
 * saisie en cours, qui vit dans [input].
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ListDetailViewModel(
    listId: String,
    private val lists: ListRepository,
    products: ProductRepository,
    categories: CategoryRepository,
    private val analyzer: EntryAnalyzer,
    remaps: Flow<IdentifierRemap> = emptyFlow(),
    private val now: () -> Instant = { Clock.System.now() },
    computation: CoroutineDispatcher = Dispatchers.Default,
    private val sharingSources: ListSharingSources = ListSharingSources(),
) : ViewModel() {
    private val currentListId = MutableStateFlow(listId)
    private val errorDetail = MutableStateFlow<String?>(null)

    /** Champ de saisie rapide, hissé ici pour survivre à la recomposition et à la rotation. */
    val input = TextFieldState()

    val listId: StateFlow<String> get() = currentListId

    private val listEntity: Flow<ShoppingListEntity?> = currentListId.flatMapLatest { lists.observeList(it) }

    private val content: Flow<Pair<String, List<ListItemEntity>>?> =
        currentListId.flatMapLatest { id ->
            combine(lists.observeList(id), lists.observeItems(id)) { list, items -> list?.let { it.name to items } }
        }

    private val participants: Flow<List<ListParticipantEntity>> =
        currentListId.flatMapLatest { sharingSources.participants(it) }

    /** Rôle, personnes, réseau et message d'accès de la liste ouverte. */
    private val sharingState: Flow<SharingInputs> =
        combine(
            listEntity,
            participants,
            sharingSources.isOnline,
            sharingSources.notices,
            currentListId,
        ) { list, people, online, notices, id ->
            SharingInputs(list?.role ?: ListRole.Owner, people, online, notices.lastOrNull { it.listId == id })
        }

    private val index: Flow<ItemSuggestionIndex> =
        combine(lists.observeItemHistory(), products.observeProducts()) { history, catalog ->
            ItemSuggestionIndex(history, catalog) { analyzer.analyze(it).normalizedName }
        }.flowOn(computation)

    private val typed: Flow<String> = snapshotFlow { input.text.toString() }

    /** Formes des articles encore à acheter : une coche ne change rien tant qu'elle ne touche pas cet ensemble. */
    private val pendingNames: Flow<Set<String>> =
        content
            .map { content ->
                content
                    ?.second
                    .orEmpty()
                    .filter { it.checkedAt == null }
                    .map { it.normalizedName }
                    .toSet()
            }.distinctUntilChanged()

    /**
     * Recherche à chaque frappe, hors du fil principal (#54) : l'analyse de la saisie et le parcours de l'index ne
     * bloquent jamais la frappe suivante, et une frappe plus récente annule le calcul en cours.
     */
    private val suggestions: Flow<List<ItemSuggestion>> =
        combine(index, typed, pendingNames, ::Triple)
            .mapLatest { (index, text, pending) ->
                withContext(computation) {
                    index.suggestions(analyzer.searchForms(analyzer.analyze(text).label), pending)
                }
            }.distinctUntilChanged()

    val uiState: StateFlow<ListDetailUiState> =
        combine(
            content,
            categories.observeCategories(),
            suggestions,
            errorDetail,
            sharingState,
        ) { content, cats, suggestions, error, sharing ->
            val items = content?.second.orEmpty()
            val authors = Authors(sharing.people)
            ListDetailUiState(
                name = content?.first.orEmpty(),
                sections = group(items.map { row(it, authors) }, cats),
                suggestions = suggestions,
                isLoaded = true,
                isMissing = content == null,
                errorDetail = error,
                sharing = sharingUi(sharing, authors, items),
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), ListDetailUiState())

    /** Le message d'accès est lu : il ne revient plus. */
    fun acknowledge(notice: AccessChange) = sharingSources.acknowledge(notice)

    init {
        viewModelScope.launch { remaps.collect { remap -> currentListId.update { remap[it] } } }
    }

    /**
     * Propositions en cours d'ajout, par forme normalisée : un double appui sur une même proposition ne l'ajoute
     * qu'une fois. Une saisie validée pendant l'écriture d'une autre n'est pas ignorée (#54) : elle attend son tour.
     */
    private val adding = mutableSetOf<String>()

    /** Les ajouts s'écrivent un par un, dans l'ordre où ils ont été validés. */
    private val writes = Mutex()

    /** Ajoute la saisie en cours. Sans effet si elle est vide (une double Entrée trouve le champ déjà vidé). */
    fun submit() {
        val text = input.text.toString()
        val entry = analyzer.analyze(text)
        if (entry.label.isEmpty()) return
        add(text, entry.label, entry.normalizedName, entry.quantity, productId = null, categoryId = entry.categoryId)
    }

    /** Ajoute une proposition en gardant la quantité déjà tapée. */
    fun add(suggestion: ItemSuggestion) {
        if (suggestion.normalizedName in adding) return
        val text = input.text.toString()
        val entry = analyzer.analyze(text)
        val categoryId = suggestion.categoryId ?: analyzer.analyze(suggestion.label).categoryId
        add(text, suggestion.label, suggestion.normalizedName, entry.quantity, suggestion.productId, categoryId)
    }

    fun toggle(row: ItemRow) {
        val at = now()
        viewModelScope.launch { perform { lists.setChecked(row.id, if (row.isChecked) null else at, at) } }
    }

    fun delete(row: ItemRow) {
        viewModelScope.launch { perform { lists.deleteItem(row.id, now()) } }
    }

    fun dismissError() = errorDetail.update { null }

    /**
     * La saisie est vidée tout de suite (un second appel ne la retrouve pas) et rendue si l'écriture échoue, sauf
     * si l'utilisateur a déjà retapé autre chose. La liste est lue au moment d'écrire : une reprise de compte faite
     * pendant l'attente est suivie.
     */
    private fun add(
        text: String,
        label: String,
        normalizedName: String,
        quantity: String?,
        productId: String?,
        categoryId: String,
    ) {
        adding += normalizedName
        input.clearText()
        // Ni annulable ni sautée : le texte a déjà quitté le champ, un Retour juste après ne doit pas perdre l'article.
        viewModelScope.launch(start = CoroutineStart.ATOMIC) {
            withContext(NonCancellable) { write(text, label, normalizedName, quantity, productId, categoryId) }
        }
    }

    private suspend fun write(
        text: String,
        label: String,
        normalizedName: String,
        quantity: String?,
        productId: String?,
        categoryId: String,
    ) {
        try {
            val added =
                writes.withLock {
                    perform {
                        lists.addItem(
                            currentListId.value,
                            label,
                            normalizedName,
                            quantity,
                            productId,
                            categoryId,
                            now(),
                        )
                    }
                }
            if (added == null && input.text.isEmpty()) input.setTextAndPlaceCursorAtEnd(text)
        } finally {
            adding -= normalizedName
        }
    }

    // Toute erreur d'écriture est montrée à l'utilisateur ; l'annulation est relancée.
    @Suppress("TooGenericExceptionCaught")
    private suspend fun <T> perform(work: suspend () -> T): T? =
        try {
            work()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorDetail.value = e.message ?: e.javaClass.simpleName
            null
        }

    companion object {
        private const val STOP_TIMEOUT_MS = 5_000L

        private fun row(
            item: ListItemEntity,
            authors: Authors,
        ): ItemRow {
            val mark = authors.mark(item.updatedBy)
            return ItemRow(
                item.id,
                item.label,
                item.quantity,
                item.categoryId,
                item.normalizedName,
                item.checkedAt != null,
                authorMark = mark,
                authorName = mark?.let { authors.name(item.updatedBy) },
            )
        }

        private fun sharingUi(
            inputs: SharingInputs,
            authors: Authors,
            items: List<ListItemEntity>,
        ): ListSharingUi {
            val others = inputs.people.filterNot { it.isMe }
            val labels = avatarLabelsOf(others.map { it.displayName })
            val latest =
                items
                    .filter { authors.mark(it.updatedBy) != null }
                    .maxByOrNull { it.updatedAt }
            return ListSharingUi(
                role = inputs.role,
                others = others.mapIndexed { i, p -> MemberChip(p.userId, labels[i], p.displayName, p.role) },
                ownerName = inputs.people.firstOrNull { it.role == ListRole.Owner }?.displayName,
                lastChange = latest?.let { LastChange(authors.name(it.updatedBy), it.updatedAt) },
                isOffline = others.isNotEmpty() && !inputs.online,
                notice = inputs.notice,
            )
        }

        /** Regroupe par rayon, dans l'ordre générique (`rank`). Un identifiant inconnu rejoint `other`. */
        fun group(
            rows: List<ItemRow>,
            categories: List<CategoryEntity>,
        ): List<ItemSection> {
            val known = categories.map { it.id }.toSet()
            val other = CategoryClassifier.OTHER_CATEGORY_ID
            val byCategory = rows.groupBy { if (it.categoryId in known) it.categoryId else other }
            val ordered =
                categories.map { it.id to it.label } + if (other !in known) listOf(other to "Autres") else emptyList()
            return ordered.mapNotNull { (id, title) -> byCategory[id]?.let { ItemSection(id, title, it) } }
        }
    }
}
