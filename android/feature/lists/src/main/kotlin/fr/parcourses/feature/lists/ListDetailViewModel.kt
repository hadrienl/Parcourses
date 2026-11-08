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
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.entity.CategoryEntity
import fr.parcourses.core.database.entity.ListItemEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Instant

/** Un article tel qu'affiché : une valeur, jamais l'entité Room. */
@Immutable
data class ItemRow(
    val id: String,
    val label: String,
    val quantity: String?,
    val categoryId: String,
    val normalizedName: String,
    val isChecked: Boolean,
) {
    /** « Tomates, 2 », suivi par TalkBack de l'état coché ou non. */
    val accessibilityLabel: String get() = listOfNotNull(label, quantity).joinToString(", ")
}

/** Articles d'un même rayon. */
@Immutable
data class ItemSection(
    val categoryId: String,
    val title: String,
    val items: List<ItemRow>,
)

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
) : ViewModel() {
    private val currentListId = MutableStateFlow(listId)
    private val errorDetail = MutableStateFlow<String?>(null)

    /** Champ de saisie rapide, hissé ici pour survivre à la recomposition et à la rotation. */
    val input = TextFieldState()

    val listId: StateFlow<String> get() = currentListId

    private val content: Flow<Pair<String, List<ListItemEntity>>?> =
        currentListId.flatMapLatest { id ->
            combine(lists.observeList(id), lists.observeItems(id)) { list, items -> list?.let { it.name to items } }
        }

    private val index: Flow<ItemSuggestionIndex> =
        combine(lists.observeItemHistory(), products.observeProducts()) { history, catalog ->
            ItemSuggestionIndex(history, catalog) { analyzer.analyze(it).normalizedName }
        }.flowOn(computation)

    private val typed: Flow<String> = snapshotFlow { input.text.toString() }

    private val suggestions: Flow<List<ItemSuggestion>> =
        combine(index, typed, content) { index, text, content ->
            val pending =
                content
                    ?.second
                    .orEmpty()
                    .filter { it.checkedAt == null }
                    .map { it.normalizedName }
                    .toSet()
            index.suggestions(analyzer.searchForms(analyzer.analyze(text).label), pending)
        }

    val uiState: StateFlow<ListDetailUiState> =
        combine(
            content,
            categories.observeCategories(),
            suggestions,
            errorDetail,
        ) { content, cats, suggestions, error ->
            ListDetailUiState(
                name = content?.first.orEmpty(),
                sections = group(content?.second.orEmpty().map(::row), cats),
                suggestions = suggestions,
                isLoaded = true,
                isMissing = content == null,
                errorDetail = error,
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), ListDetailUiState())

    init {
        viewModelScope.launch { remaps.collect { remap -> currentListId.update { remap[it] } } }
    }

    /** Une écriture d'ajout est en cours : tout nouvel ajout est ignoré (double Entrée, double appui). */
    private var isAdding = false

    /** Ajoute la saisie en cours. Sans effet si elle est vide. */
    fun submit() {
        if (isAdding) return
        val text = input.text.toString()
        val entry = analyzer.analyze(text)
        if (entry.label.isEmpty()) return
        add(text, entry.label, entry.normalizedName, entry.quantity, productId = null, categoryId = entry.categoryId)
    }

    /** Ajoute une proposition en gardant la quantité déjà tapée. */
    fun add(suggestion: ItemSuggestion) {
        if (isAdding) return
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
     * si l'utilisateur a déjà retapé autre chose.
     */
    private fun add(
        text: String,
        label: String,
        normalizedName: String,
        quantity: String?,
        productId: String?,
        categoryId: String,
    ) {
        val id = currentListId.value
        isAdding = true
        input.clearText()
        viewModelScope.launch {
            try {
                val added = perform { lists.addItem(id, label, normalizedName, quantity, productId, categoryId, now()) }
                if (added == null && input.text.isEmpty()) input.setTextAndPlaceCursorAtEnd(text)
            } finally {
                isAdding = false
            }
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

        private fun row(item: ListItemEntity) =
            ItemRow(item.id, item.label, item.quantity, item.categoryId, item.normalizedName, item.checkedAt != null)

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
