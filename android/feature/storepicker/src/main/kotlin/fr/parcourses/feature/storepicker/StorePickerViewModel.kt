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
    /**
     * La recherche par nom est offerte dès que la position est traitée : le magasin voulu peut manquer aux plus
     * proches, et elle sert de repli quand la position n'a rien donné.
     */
    val offersSearch: Boolean
        get() = phase != StorePickerPhase.Loading
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
    private val permissionMemory: LocationPermissionMemory = InMemoryLocationPermissionMemory(),
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
    private var finished = false
    private var permissionRequested = false
    private var canAskAgain = true
    private var lastAuthorization: LocationAuthorization? = null

    /** La personne est partie activer la localisation du téléphone : à son retour, on relit la position. */
    private var awaitingLocationSettings = false

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
     * demander » ou un deuxième refus. [couldAskBefore] : la même valeur lue juste avant la demande.
     *
     * Le refus n'est retenu comme définitif d'une ouverture à l'autre que s'il passe de vrai à faux (#54) : depuis
     * Android 11, un dialogue simplement fermé (appui à côté, Retour) donne aussi faux, sans rien interdire.
     */
    fun onPermissionResult(
        canAskAgain: Boolean,
        couldAskBefore: Boolean = false,
    ) {
        permissionRequested = true
        this.canAskAgain = canAskAgain
        val current = state.value.phase
        val authorization = location.authorization
        // Un refus définitif survit à l'écran (#54) : sans cela, le premier appui sur « Utiliser ma position » d'une
        // prochaine fois ne ferait rien, la demande système ne s'ouvrant plus.
        permissionMemory.deniedPermanently =
            authorization == LocationAuthorization.Denied && !canAskAgain && couldAskBefore
        when (authorization) {
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

    /** L'écran ouvre les réglages de localisation du téléphone (position désactivée). */
    fun locationSettingsOpened() {
        awaitingLocationSettings = true
    }

    /**
     * Retour au premier plan : les réglages ont pu rendre l'accès à la position, ou activer la localisation du
     * téléphone (#54 : sans relance, il fallait appuyer sur « Réessayer »).
     */
    fun refreshAfterForeground() {
        if (awaitingLocationSettings && state.value.phase == StorePickerPhase.LocationUnavailable) {
            awaitingLocationSettings = false
            start()
            return
        }
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
        if (authorization == LocationAuthorization.Denied) {
            showDenied()
        } else {
            // Accès rendu depuis les réglages : le refus définitif retenu n'a plus cours.
            if (permissionMemory.deniedPermanently) permissionMemory.deniedPermanently = false
            locate(authorization)
        }
    }

    private fun showDenied() {
        lastAuthorization = LocationAuthorization.Denied
        // Refus définitif d'une fois précédente : les réglages tout de suite, la demande système ne s'ouvrirait plus.
        if (!permissionRequested && permissionMemory.deniedPermanently) {
            permissionRequested = true
            canAskAgain = false
        }
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
            if (e.meansOffline()) StorePickerPhase.Offline else StorePickerPhase.ServiceError
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

    /**
     * Écrit le magasin dans le cache (sans distance : avec la date, elle situerait l'utilisateur) puis le rend.
     * [finished] est posé avant tout envoi : un double appui, ou un appui sur « sans magasin » pendant l'écriture,
     * ne produit qu'une sortie. Seul un échec le relève, pour réessayer.
     */
    @Suppress("TooGenericExceptionCaught") // toute panne de cache est dite à l'utilisateur, l'annulation est relancée
    fun select(store: StoreCandidate) {
        if (finished) return
        finished = true
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
                finished = false
                state.update { it.copy(selectionFailed = true) }
            }
        }
    }

    fun dismissSelectionFailure() = state.update { it.copy(selectionFailed = false) }

    fun continueWithoutStore() {
        if (finished) return
        finished = true
        cancel()
        outcomeChannel.trySend(StorePickerOutcome.WithoutStore)
    }

    // MARK: recherche

    fun onQueryChange(text: String) {
        if (text == state.value.query) return
        state.update { it.copy(query = text) }
        scheduleSearch(text.trim(), immediate = false)
    }

    /** Touche « Rechercher » du clavier : lance la recherche sans attendre l'anti-rebond. */
    fun submitSearch() = scheduleSearch(state.value.query.trim(), immediate = true)

    private fun scheduleSearch(
        text: String,
        immediate: Boolean,
    ) {
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
                if (!immediate) delay(debounceMs)
                val result =
                    try {
                        val rows =
                            withTimeoutOrNull(requestTimeoutMs) { remote.searchStores(text, StoreRanking.SEARCH_LIMIT) }
                        rows?.let { StoreSearchState.Results(it.map { row -> row.toCandidate() }) }
                            ?: StoreSearchState.Offline
                    } catch (e: RemoteError) {
                        if (e.meansOffline()) StoreSearchState.Offline else StoreSearchState.Failed
                    }
                state.update { it.copy(search = result) }
            }
    }

    /**
     * Réseau absent, ou session anonyme pas encore créée (premier lancement hors ligne, `Unauthorized`) : dans les
     * deux cas, il faut du réseau, et le service n'est pas en cause (#54). Une session perdue en ligne donne aussi
     * `Unauthorized` : l'écran dit alors « hors ligne » jusqu'à ce que la synchronisation reprenne le compte, ce qui
     * reste le conseil utile (réessayer plus tard, ou continuer sans magasin).
     */
    private fun RemoteError.meansOffline(): Boolean = this is RemoteError.Network || this is RemoteError.Unauthorized

    companion object {
        const val MIN_QUERY_LENGTH = 2
        private const val DEBOUNCE_MS = 300L
        private const val REQUEST_TIMEOUT_MS = 10_000L
    }
}
