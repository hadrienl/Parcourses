package fr.parcourses.feature.storepicker

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.repository.StoreRepository
import fr.parcourses.core.location.LocationAuthorization
import fr.parcourses.core.location.LocationFix
import fr.parcourses.core.location.LocationProvider
import fr.parcourses.core.location.LocationResult
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.NearbyStoreRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.text.Collator
import java.util.Locale
import kotlin.time.Clock
import kotlin.time.Instant

/** Ce que l'écran montre pour la position. */
sealed interface StorePickerPhase {
    data object Loading : StorePickerPhase

    /** Localisation pas encore demandée : l'écran l'explique avant d'ouvrir la demande système. */
    data object PermissionNeeded : StorePickerPhase

    /** Position précise : un magasin proposé (ou aucun si c'est ambigu), puis les autres. */
    data class Precise(
        val proposed: StoreCandidate?,
        val others: List<StoreCandidate>,
    ) : StorePickerPhase

    /** Position approximative : aucune devinette, candidats à égalité. */
    data class Approximate(
        val candidates: List<StoreCandidate>,
    ) : StorePickerPhase

    /**
     * Localisation refusée. [canAskAgain] faux : « Ne plus demander » (ou deuxième refus), seuls les réglages de
     * l'app peuvent la rendre.
     */
    data class Denied(
        val canAskAgain: Boolean,
    ) : StorePickerPhase

    /** Autorisée, mais aucun point obtenu. */
    data object LocationUnavailable : StorePickerPhase

    data object Offline : StorePickerPhase

    /** Le service a répondu par une erreur : réessayable, sans donner le réseau pour coupable. */
    data object ServiceError : StorePickerPhase

    /** Aucun magasin dans le rayon. */
    data object NoStore : StorePickerPhase
}

/** Résultat d'une recherche par nom. */
sealed interface StoreSearchState {
    data object Idle : StoreSearchState

    data object Searching : StoreSearchState

    data class Results(
        val stores: List<StoreCandidate>,
    ) : StoreSearchState

    data object Offline : StoreSearchState

    data object Failed : StoreSearchState
}

@Immutable
data class StorePickerUiState(
    val phase: StorePickerPhase = StorePickerPhase.Loading,
    val recents: List<StoreCandidate> = emptyList(),
    val query: String = "",
    val search: StoreSearchState = StoreSearchState.Idle,
    val selectionFailed: Boolean = false,
    /** La demande de précision n'a rien donné : à dire, sinon le bouton semble sans effet. */
    val precisionDeclined: Boolean = false,
) {
    /** La recherche par nom sert de repli quand la position n'a rien donné d'utilisable. */
    val offersSearch: Boolean
        get() =
            when (phase) {
                is StorePickerPhase.Denied,
                StorePickerPhase.PermissionNeeded,
                StorePickerPhase.LocationUnavailable,
                StorePickerPhase.NoStore,
                is StorePickerPhase.Approximate,
                -> true

                StorePickerPhase.Loading,
                is StorePickerPhase.Precise,
                StorePickerPhase.Offline,
                StorePickerPhase.ServiceError,
                -> false
            }
}

/**
 * Modèle de l'écran de choix du magasin (#10 §7 et §8). La position reste en mémoire le temps d'une requête à
 * `nearby_stores` : elle n'est ni enregistrée ni journalisée, et seul le magasin choisi entre dans le cache,
 * sans distance. Sans [gateway] (pas de configuration Supabase), l'app reste locale comme hors ligne.
 */
@Suppress("TooManyFunctions") // un point d'entrée par action de l'écran
class StorePickerViewModel(
    private val location: LocationProvider,
    private val gateway: RemoteGateway?,
    private val stores: StoreRepository,
    private val debounceMs: Long = DEBOUNCE_MS,
    private val requestTimeoutMs: Long = REQUEST_TIMEOUT_MS,
    private val now: () -> Instant = { Clock.System.now() },
) : ViewModel() {
    private val state = MutableStateFlow(StorePickerUiState())
    val uiState: StateFlow<StorePickerUiState> = state.asStateFlow()

    private val outcomeChannel = Channel<StorePickerOutcome>(Channel.BUFFERED)

    /** Choix fait, à consommer une fois. */
    val outcomes: Flow<StorePickerOutcome> = outcomeChannel.receiveAsFlow()

    private var loadJob: Job? = null
    private var searchJob: Job? = null
    private var started = false
    private var selecting = false
    private var permissionRequested = false
    private var canAskAgain = true
    private var lastAuthorization: LocationAuthorization? = null

    /** À l'ouverture de l'écran : ne relance pas une recherche déjà en cours ou terminée (rotation). */
    fun ensureStarted() {
        if (!started) start()
    }

    /** Lance le chargement et remplace celui en cours : un seul à la fois. */
    fun start() {
        started = true
        loadJob?.cancel()
        state.update { it.copy(phase = StorePickerPhase.Loading, precisionDeclined = false) }
        reloadRecents()
        loadJob = viewModelScope.launch { load() }
    }

    /**
     * Retour de la demande système. [canAskAgain] : `shouldShowRequestPermissionRationale`, faux après « Ne plus
     * demander » ou un deuxième refus.
     */
    fun onPermissionResult(canAskAgain: Boolean) {
        permissionRequested = true
        this.canAskAgain = canAskAgain
        val current = state.value.phase
        when (location.authorization) {
            LocationAuthorization.Denied -> {
                showDenied()
            }

            // Précision demandée mais seule l'approximative est accordée.
            LocationAuthorization.Approximate -> {
                if (current is StorePickerPhase.Approximate) {
                    state.update { it.copy(precisionDeclined = true) }
                } else {
                    startUnlessLoading()
                }
            }

            LocationAuthorization.Precise -> {
                startUnlessLoading()
            }
        }
    }

    // Le retour au premier plan après la demande système a déjà pu relancer le chargement.
    private fun startUnlessLoading() {
        if (loadJob?.isActive == true && lastAuthorization == location.authorization) return
        start()
    }

    /** Retour au premier plan : les réglages ont pu rendre l'accès à la position. */
    fun refreshAfterForeground() {
        val waiting =
            when (state.value.phase) {
                is StorePickerPhase.Denied,
                is StorePickerPhase.Approximate,
                StorePickerPhase.PermissionNeeded,
                -> true

                else -> false
            }
        if (waiting && location.authorization != lastAuthorization) start()
    }

    /** Fermeture de l'écran : aucune position ne doit partir ensuite. */
    fun cancel() {
        loadJob?.cancel()
        searchJob?.cancel()
    }

    override fun onCleared() = cancel()

    private suspend fun load() {
        val authorization = location.authorization
        lastAuthorization = authorization
        if (authorization == LocationAuthorization.Denied) showDenied() else locate(authorization)
    }

    private fun showDenied() {
        lastAuthorization = LocationAuthorization.Denied
        val phase =
            if (permissionRequested) StorePickerPhase.Denied(canAskAgain) else StorePickerPhase.PermissionNeeded
        state.update { it.copy(phase = phase) }
    }

    private suspend fun locate(authorization: LocationAuthorization) {
        val remote = gateway
        if (remote == null) {
            setPhase(StorePickerPhase.Offline)
            return
        }
        when (val result = location.currentFix()) {
            is LocationResult.Fix -> {
                setPhase(nearby(remote, result.fix, isPrecise = authorization == LocationAuthorization.Precise))
            }

            LocationResult.Denied -> {
                permissionRequested = true
                showDenied()
            }

            LocationResult.Unavailable -> {
                setPhase(StorePickerPhase.LocationUnavailable)
            }
        }
    }

    private suspend fun nearby(
        remote: RemoteGateway,
        fix: LocationFix,
        isPrecise: Boolean,
    ): StorePickerPhase {
        val radius = if (isPrecise) StoreRanking.PRECISE_RADIUS_M else StoreRanking.APPROXIMATE_RADIUS_M
        return try {
            val rows =
                withTimeoutOrNull(requestTimeoutMs) {
                    remote.nearbyStores(fix.latitude, fix.longitude, radius, StoreRanking.MAX_RESULTS)
                } ?: return StorePickerPhase.Offline
            phase(rows, isPrecise, fix)
        } catch (e: RemoteError) {
            // Une annulation est relancée par le gateway : seule une vraie panne arrive ici.
            if (e is RemoteError.Network) StorePickerPhase.Offline else StorePickerPhase.ServiceError
        }
    }

    private fun phase(
        rows: List<NearbyStoreRow>,
        isPrecise: Boolean,
        fix: LocationFix,
    ): StorePickerPhase =
        when {
            rows.isEmpty() -> {
                StorePickerPhase.NoStore
            }

            // Le point approximatif ne permet pas de classer : à égalité, par ordre alphabétique.
            !isPrecise -> {
                val collator = Collator.getInstance(Locale.FRENCH)
                val candidates = rows.map { it.toCandidate(keepsDistance = false) }
                StorePickerPhase.Approximate(candidates.sortedWith(compareBy(collator) { it.name }))
            }

            else -> {
                val candidates = rows.map { it.toCandidate(keepsDistance = true) }
                val proposed = StoreRanking.proposal(candidates, fix)
                StorePickerPhase.Precise(proposed, candidates.filter { it.id != proposed?.id })
            }
        }

    private fun setPhase(phase: StorePickerPhase) = state.update { it.copy(phase = phase) }

    private fun reloadRecents() {
        viewModelScope.launch {
            // Le cache est un confort : illisible, il ne doit pas bloquer le choix en ligne.
            val cached = runCatching { stores.recentStores(StoreRanking.RECENT_LIMIT) }.getOrNull().orEmpty()
            state.update { ui ->
                ui.copy(recents = cached.map { StoreCandidate(it.id, it.name, it.chain, it.address) })
            }
        }
    }

    // MARK: choix

    /** Écrit le magasin dans le cache (sans distance : avec la date, elle situerait l'utilisateur) puis le rend. */
    @Suppress("TooGenericExceptionCaught") // toute panne de cache est dite à l'utilisateur, l'annulation est relancée
    fun select(store: StoreCandidate) {
        if (selecting) return
        selecting = true
        viewModelScope.launch {
            try {
                stores.upsertStore(store.id, store.name, store.chain, store.address, store.organicAisle)
                stores.markUsed(store.id, now())
                state.update { it.copy(selectionFailed = false) }
                cancel()
                outcomeChannel.send(StorePickerOutcome.Store(store.id))
            } catch (e: CancellationException) {
                throw e
            } catch (ignored: Exception) {
                state.update { it.copy(selectionFailed = true) }
            } finally {
                selecting = false
            }
        }
    }

    fun dismissSelectionFailure() = state.update { it.copy(selectionFailed = false) }

    fun continueWithoutStore() {
        cancel()
        outcomeChannel.trySend(StorePickerOutcome.WithoutStore)
    }

    // MARK: recherche

    fun onQueryChange(text: String) {
        if (text == state.value.query) return
        state.update { it.copy(query = text) }
        scheduleSearch(text.trim())
    }

    private fun scheduleSearch(text: String) {
        searchJob?.cancel()
        if (text.length < MIN_QUERY_LENGTH) {
            state.update { it.copy(search = StoreSearchState.Idle) }
            return
        }
        val remote = gateway
        if (remote == null) {
            state.update { it.copy(search = StoreSearchState.Offline) }
            return
        }
        state.update { it.copy(search = StoreSearchState.Searching) }
        searchJob =
            viewModelScope.launch {
                delay(debounceMs)
                val result =
                    try {
                        val rows =
                            withTimeoutOrNull(requestTimeoutMs) { remote.searchStores(text, StoreRanking.SEARCH_LIMIT) }
                        rows?.let { StoreSearchState.Results(it.map { row -> row.toCandidate() }) }
                            ?: StoreSearchState.Offline
                    } catch (e: RemoteError) {
                        if (e is RemoteError.Network) StoreSearchState.Offline else StoreSearchState.Failed
                    }
                state.update { it.copy(search = result) }
            }
    }

    companion object {
        const val MIN_QUERY_LENGTH = 2
        private const val DEBOUNCE_MS = 300L
        private const val REQUEST_TIMEOUT_MS = 10_000L
    }
}
