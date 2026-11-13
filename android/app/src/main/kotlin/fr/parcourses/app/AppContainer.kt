package fr.parcourses.app

import android.content.Context
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionFlag
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.account.SharedPreferencesAccountDeletionFlag
import fr.parcourses.core.data.repository.CategoryRepository
import fr.parcourses.core.data.repository.GraphRepository
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.ProductRepository
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomGraphRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.repository.RoomStoreRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.repository.StoreRepository
import fr.parcourses.core.data.repository.VisitRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.data.sync.NetworkMonitor
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SharedPreferencesSyncCursors
import fr.parcourses.core.data.sync.SyncCoordinator
import fr.parcourses.core.data.sync.SyncCursors
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.data.sync.WorkManagerSyncScheduler
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.location.LocationProvider
import fr.parcourses.core.location.SystemLocationProvider
import fr.parcourses.core.network.AuthBootstrap
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SessionMaintenance
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.SupabaseGateway
import fr.parcourses.core.network.createSupabaseGateway
import fr.parcourses.feature.shopping.GraphSnapshotCache
import fr.parcourses.feature.shopping.ShoppingDependencies
import fr.parcourses.feature.shopping.ShoppingTimings
import fr.parcourses.feature.shopping.live.LiveUpdatePreferences
import fr.parcourses.feature.shopping.live.SharedPreferencesLiveUpdatePreferences
import fr.parcourses.feature.shopping.live.ShoppingLiveUpdates
import fr.parcourses.feature.shopping.live.SystemLiveUpdateNotifier
import fr.parcourses.feature.storepicker.LocationPermissionMemory
import fr.parcourses.feature.storepicker.SharedPreferencesLocationPermissionMemory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Dispatchers.IO
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Visite ouverte que l'app rouvre au lancement. */
data class ResumableVisit(
    val listId: String,
    val storeId: String,
    val visitId: String,
)

/**
 * Racine de l'injection, à la main (une seule instance par processus). Tout est créé à la demande : rien
 * n'ouvre la base ni le réseau avant le premier usage. Sans configuration Supabase, [engine] est `null` et l'app
 * reste entièrement locale (la file d'envoi se remplit, rien ne part).
 */
@Suppress("TooManyFunctions")
class AppContainer(
    private val context: Context,
    private val config: SupabaseConfig? =
        SupabaseConfig.create(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY),
    /** Ouverture de la base : celle de l'app, ou une base en mémoire pour les tests. */
    private val openDatabase: (Context) -> ParcoursesDatabase = { ParcoursesDatabaseFactory.create(it, IO) },
) {
    val database: ParcoursesDatabase by lazy { openDatabase(context) }

    /** Drapeau durable de « Supprimer mes données » (#68) : tant qu'il existe, ni synchronisation ni compte créé. */
    val deletionFlag: AccountDeletionFlag by lazy { SharedPreferencesAccountDeletionFlag(context) }

    private val supabase: SupabaseGateway? by lazy { config?.let { createSupabaseGateway(context, it) } }

    /** Toute l'app passe par la garde : aucun `ensureSession` pendant une suppression du compte. */
    val gateway: RemoteGateway? by lazy { supabase?.let { DeletionGuardedGateway(it, deletionFlag) } }

    /** Entretien de la session (écran À propos) : `null` sans configuration Supabase. */
    val sessionMaintenance: SessionMaintenance? get() = supabase

    val scheduler by lazy { WorkManagerSyncScheduler(context) }

    private val networkMonitor by lazy { NetworkMonitor(context, onReturn = { coordinator?.requestSync(pull = true) }) }
    private val networkStarted = AtomicBoolean(false)

    private val cursors: SyncCursors by lazy { SharedPreferencesSyncCursors(context) }

    /**
     * Tout ce qui garde un état en mémoire lié au compte : le moteur (curseurs en cours, `remapHistory`, délais), son
     * coordinateur, la Live Update (`current`, `posted`) et le mode courses qui la porte. [reset] les recrée.
     */
    private inner class Session {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

        val engine: SyncEngine? by lazy {
            gateway?.let { remote ->
                SyncEngine(
                    gateway = remote,
                    db = database,
                    cursors = cursors,
                    classify = pulledItemClassifier(),
                    dependencies =
                        SyncDependencies(
                            isOnline = { networkMonitor.isOnline },
                            isAccountDeletionPending = { deletionFlag.isPending },
                        ),
                )
            }
        }

        val coordinator: SyncCoordinator? by lazy { engine?.let { SyncCoordinator(it, scheduler) } }

        val liveUpdates: ShoppingLiveUpdates by lazy {
            ShoppingLiveUpdates(
                notifier = notifier,
                visits = visits,
                lists = lists,
                analyzer = analyzer,
                preferences = livePreferences,
                scope = scope,
                remaps = remaps,
            )
        }

        val shopping: ShoppingDependencies by lazy {
            ShoppingDependencies(
                lists,
                visits,
                stores,
                categories,
                analyzer,
                GraphSnapshotCache(graphs, gateway),
                liveUpdates,
            )
        }

        fun close() = scope.cancel()
    }

    @Volatile
    private var session = Session()

    /** Augmente à chaque [reset] : la navigation et les flux qui suivent le moteur courant s'y abonnent. */
    private val sessionGeneration = MutableStateFlow(0)
    val generation: StateFlow<Int> = sessionGeneration.asStateFlow()

    private val navigationReset = AtomicBoolean(false)

    val engine: SyncEngine? get() = session.engine

    val coordinator: SyncCoordinator? get() = session.coordinator

    /**
     * Reprises de compte du moteur courant, y compris après un [reset] : les écrans et la Live Update s'abonnent ici
     * une fois pour toutes.
     */
    @OptIn(ExperimentalCoroutinesApi::class)
    val remaps: Flow<IdentifierRemap> = sessionGeneration.flatMapLatest { session.engine?.remaps ?: emptyFlow() }

    /** Une nouvelle entrée de file réveille la synchronisation. */
    val lists: ListRepository by lazy { RoomListRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val products: ProductRepository by lazy { RoomProductRepository(database) }
    val categories: CategoryRepository by lazy { RoomCategoryRepository(database) }
    val analyzer: EntryAnalyzer by lazy { EntryAnalyzer() }
    val stores: StoreRepository by lazy { RoomStoreRepository(database) }

    /** Position ponctuelle : Google Play Services, sinon le gestionnaire du système (API 30+). */
    val location: LocationProvider by lazy { SystemLocationProvider(context) }

    /** Refus définitif de la localisation, retenu d'une ouverture du choix du magasin à l'autre. */
    val locationPermission: LocationPermissionMemory by lazy { SharedPreferencesLocationPermissionMemory(context) }

    val visits: VisitRepository by lazy { RoomVisitRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val graphs: GraphRepository by lazy { RoomGraphRepository(database) }

    /** Tout ce que le mode courses lit et écrit (instantané du graphe compris). */
    val shopping: ShoppingDependencies get() = session.shopping

    val livePreferences: LiveUpdatePreferences by lazy { SharedPreferencesLiveUpdatePreferences(context) }

    private val notifier by lazy { SystemLiveUpdateNotifier(context) }

    /**
     * Live Update du mode courses : **une seule instance** à la fois, pour l'écran comme pour le receiver. Recréée
     * par [reset] après une suppression des données.
     */
    val liveUpdates: ShoppingLiveUpdates get() = session.liveUpdates

    private val deepLinks = Channel<String>(Channel.BUFFERED)

    /** Visites demandées par la Live Update (`parcourses://shopping/<id>`) : un seul collecteur, toujours composé. */
    val shoppingLinks: Flow<String> = deepLinks.receiveAsFlow()

    fun offerShoppingLink(visitId: String) {
        deepLinks.trySend(visitId)
    }

    /**
     * Visite à rouvrir pour un lien de la Live Update : seulement si c'est la visite ouverte et encore active (mêmes
     * règles qu'au lancement, voir [resumableVisit]). Sinon la notification, périmée, est retirée.
     */
    suspend fun linkedVisit(visitId: String): ResumableVisit? {
        // Suppression des données en cours : aucun mode courses ne se rouvre.
        if (accountDeletion.state.value != AccountDeletionState.Idle) return null
        val visit = resumableVisit()
        liveUpdates.reconcile()
        return visit?.takeIf { it.visitId == visitId }
    }

    private val storeChoiceEvents = StoreChoiceEvents()

    /** Choix de magasin à consommation unique : voir [StoreChoiceEvents] pour le contrat du collecteur. */
    val storeChoices: Flow<StoreChoice> get() = storeChoiceEvents.choices

    fun offerStoreChoice(choice: StoreChoice) = storeChoiceEvents.offer(choice)

    /** Reprise de la visite ouverte : une fois par processus, au lancement à froid (voir [LaunchResume]). */
    val launchResume = LaunchResume()

    /**
     * Visite ouverte à reprendre au lancement, vérifiée. Sa liste a pu disparaître, ou elle est restée sans coche
     * depuis plus de [expiry] : elle est alors abandonnée (close à sa dernière coche, supprimée si elle n'en a
     * aucune et n'est jamais partie, ses introuvables remis à acheter : voir `VisitRepository.abandonVisit`) et rien
     * n'est rouvert.
     * L'abandon ne lève rien sur une visite disparue entre-temps (reprise de compte) : le lancement ne plante pas,
     * et une visite redevenue active entre la lecture et l'abandon reste ouverte.
     */
    suspend fun resumableVisit(expiry: Duration = ShoppingTimings().expiry): ResumableVisit? {
        // Suppression interrompue : la visite va être effacée, elle n'est pas rouverte (ni abandonnée vers le serveur).
        // Le drapeau est lu sur le disque : jamais sur le fil principal, d'où vient la reprise au lancement.
        val pending = withContext(IO) { deletionFlag.isPending }
        val visit = (if (pending) null else visits.openVisit()) ?: return null
        val now = Clock.System.now()
        val last = visits.lastActivity(visit.id) ?: visit.startedAt
        val listExists = lists.list(visit.listId) != null
        val usable = listExists && now - last < expiry
        // Liste disparue : abandon sans condition. Sinon seulement si la visite est encore périmée dans la transaction.
        if (!usable) visits.abandonVisit(visit.id, now, staleAfter = if (listExists) expiry else Duration.ZERO)
        return if (usable) ResumableVisit(visit.listId, visit.storeId, visit.id) else null
    }

    /**
     * Lancement : catégories, connexion anonyme, puis synchronisation (en tâche de fond). Si une suppression des
     * données a été interrompue (drapeau présent), ni synchronisation ni connexion : elle reprend d'abord.
     */
    fun start(scope: CoroutineScope) {
        scope.launch {
            categories.seedIfNeeded()
            if (gateway != null) startNetworkMonitor()
            if (accountDeletion.resumeAtLaunch()) return@launch
            // Une Live Update restée d'un lancement précédent ne survit que si sa visite est encore ouverte.
            liveUpdates.reconcile()
            gateway?.let { remote ->
                coordinator?.start()
                // Un échec n'empêche rien : tout est local et la file attend.
                AuthBootstrap.signIn(remote)
                coordinator?.sessionDidChange()
            }
        }
    }

    private fun startNetworkMonitor() {
        if (networkStarted.compareAndSet(false, true)) networkMonitor.start()
    }

    /** Suites réseau des actions d'entretien : elles survivent à l'écran qui les a lancées. */
    private val maintenanceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** « Supprimer mes données » (#68 §5.3) : voir [AccountDeletion]. */
    val accountDeletion: AccountDeletionController by lazy {
        AccountDeletionController(
            AccountDeletion(
                gateway = gateway,
                flag = deletionFlag,
                purge = LocalDataPurge(database, cursors),
                host = DeletionHost(),
                isOnline = { networkMonitor.isOnline },
            ),
            maintenanceScope,
        )
    }

    /** Build sans Supabase : la suppression ne purge que l'appareil (§5.7). */
    val isLocalOnly: Boolean get() = config == null

    /**
     * Recrée tout ce qui a un état en mémoire ([Session]) et demande à la navigation de repartir sur les listes, pile
     * vidée. Le moteur et la Live Update d'avant sont arrêtés pour de bon.
     */
    fun reset() {
        val old = session
        session = Session()
        navigationReset.set(true)
        sessionGeneration.update { it + 1 }
        old.close()
    }

    /** `true` une fois après chaque [reset] : la navigation vide alors sa pile. */
    fun consumeNavigationReset(): Boolean = navigationReset.getAndSet(false)

    /** Ce que la suppression demande à l'app, étape par étape. */
    private inner class DeletionHost : AccountDeletionHost {
        override suspend fun suspendSync() {
            // Sans Supabase, ni moteur ni travaux.
            coordinator?.suspend()
        }

        override suspend fun endShopping() {
            // Le mode courses se ferme dans la navigation (voile affiché), sans `closeVisit` : la visite sera effacée.
            val ended = withTimeoutOrNull(LIVE_UPDATE_BUDGET) { liveUpdates.endAll().await() }
            // Boucle de la Live Update bloquée : la notification part quand même.
            if (ended == null) notifier.cancel()
        }

        override suspend fun clearLocalState() {
            // Base vidée : une notification reposée entre-temps part, puis les préférences. Un échec lève (doute).
            notifier.cancel()
            livePreferences.clear()
        }

        override fun resumeSync() {
            liveUpdates.resume()
            // `sessionDidChange` relance le moteur (`SyncEngine.resume`) puis une passe avec descente.
            coordinator?.start()
            coordinator?.sessionDidChange()
        }

        override suspend fun rebuild() {
            reset()
            // La nouvelle instance retire toute notification sans visite ouverte (il n'y en a plus).
            liveUpdates.reconcile()
            coordinator?.start()
            coordinator?.sessionDidChange()
        }
    }

    /**
     * « Réinitialiser la session » : session oubliée, puis, en tâche de fond, nouveau compte anonyme et
     * synchronisation, qui réidentifie les données locales pour ce compte (voir [SessionMaintenance.resetSession]).
     * @return `false` si la clé s'ouvre de nouveau : rien n'a été oublié.
     * @throws fr.parcourses.core.network.RemoteError si la session n'a pas pu être oubliée.
     */
    suspend fun resetSession(): Boolean {
        val reset = sessionMaintenance?.resetSession() == true
        if (reset) {
            maintenanceScope.launch {
                // Hors ligne, la connexion échoue sans bruit : la synchronisation la retentera.
                gateway?.let { AuthBootstrap.signIn(it) }
                coordinator?.sessionDidChange()
            }
        }
        return reset
    }

    /** Premier plan : une passe avec descente. */
    fun onForeground() {
        coordinator?.requestSync(pull = true)
    }

    private fun pulledItemClassifier(): (String) -> PulledItemClassification {
        val classifier = CategoryClassifier()
        return { label -> classifier.classify(label).let { PulledItemClassification(it.normalized, it.categoryId) } }
    }

    private companion object {
        val LIVE_UPDATE_BUDGET = 3.seconds
    }
}
