package fr.parcourses.feature.lists

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.ListSummary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Instant

/** État de l'écran Listes. [isLoaded] évite d'afficher « Aucune liste » avant la première lecture. */
@Immutable
data class ListsUiState(
    val lists: List<ListSummary> = emptyList(),
    val isLoaded: Boolean = false,
    /** Détail de la dernière erreur d'écriture, à afficher puis à acquitter. */
    val errorDetail: String? = null,
)

/** Modèle de l'écran Listes : les listes viennent de Room, les écritures passent par le repository. */
class ListsViewModel(
    private val repository: ListRepository,
    private val now: () -> Instant = { Clock.System.now() },
) : ViewModel() {
    private val errorDetail = MutableStateFlow<String?>(null)

    val uiState: StateFlow<ListsUiState> =
        combine(repository.observeSummaries(), errorDetail) { lists, error ->
            ListsUiState(lists = lists, isLoaded = true, errorDetail = error)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(STOP_TIMEOUT_MS), ListsUiState())

    /** Crée une liste et la rend à [onCreated]. Sans effet si le nom est vide. */
    fun create(
        name: String,
        onCreated: (String) -> Unit,
    ) {
        val cleaned = cleaned(name) ?: return
        viewModelScope.launch {
            perform { repository.createList(cleaned, now()) }?.let { onCreated(it.id) }
        }
    }

    fun rename(
        id: String,
        name: String,
    ) {
        val cleaned = cleaned(name) ?: return
        viewModelScope.launch { perform { repository.renameList(id, cleaned, now()) } }
    }

    fun delete(id: String) {
        viewModelScope.launch { perform { repository.deleteList(id, now()) } }
    }

    fun dismissError() = errorDetail.update { null }

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

        /** Vrai si le nom saisi peut être enregistré. */
        fun isValid(name: String): Boolean = cleaned(name) != null

        fun cleaned(name: String): String? = name.trim().takeIf { it.isNotEmpty() }
    }
}
