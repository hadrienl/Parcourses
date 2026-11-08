package fr.parcourses.app

import android.content.Context
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.EntryAnalyzer
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
import fr.parcourses.core.data.sync.NetworkMonitor
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SharedPreferencesSyncCursors
import fr.parcourses.core.data.sync.SyncCoordinator
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.data.sync.WorkManagerSyncScheduler
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.location.LocationProvider
import fr.parcourses.core.location.SystemLocationProvider
import fr.parcourses.core.network.AuthBootstrap
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SupabaseConfig
import fr.parcourses.core.network.createSupabaseGateway
import fr.parcourses.feature.shopping.GraphSnapshotCache
import fr.parcourses.feature.shopping.ShoppingDependencies
import fr.parcourses.feature.shopping.ShoppingTimings
import fr.parcourses.feature.shopping.live.LiveUpdatePreferences
import fr.parcourses.feature.shopping.live.SharedPreferencesLiveUpdatePreferences
import fr.parcourses.feature.shopping.live.ShoppingLiveUpdates
import fr.parcourses.feature.shopping.live.SystemLiveUpdateNotifier
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration

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
class AppContainer(
    private val context: Context,
    private val config: SupabaseConfig? =
        SupabaseConfig.create(BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY),
) {
    val database: ParcoursesDatabase by lazy { ParcoursesDatabaseFactory.create(context, Dispatchers.IO) }

    val gateway: RemoteGateway? by lazy { config?.let { createSupabaseGateway(context, it) } }

    val scheduler by lazy { WorkManagerSyncScheduler(context) }

    private val networkMonitor by lazy { NetworkMonitor(context, onReturn = { coordinator?.requestSync(pull = true) }) }

    val engine: SyncEngine? by lazy {
        gateway?.let { remote ->
            SyncEngine(
                gateway = remote,
                db = database,
                cursors = SharedPreferencesSyncCursors(context),
                classify = pulledItemClassifier(),
                dependencies = SyncDependencies(isOnline = { networkMonitor.isOnline }),
            )
        }
    }

    val coordinator: SyncCoordinator? by lazy { engine?.let { SyncCoordinator(it, scheduler) } }

    /** Une nouvelle entrée de file réveille la synchronisation. */
    val lists: ListRepository by lazy { RoomListRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val products: ProductRepository by lazy { RoomProductRepository(database) }
    val categories: CategoryRepository by lazy { RoomCategoryRepository(database) }
    val analyzer: EntryAnalyzer by lazy { EntryAnalyzer() }
    val stores: StoreRepository by lazy { RoomStoreRepository(database) }

    /** Position ponctuelle : Google Play Services, sinon le gestionnaire du système (API 30+). */
    val location: LocationProvider by lazy { SystemLocationProvider(context) }

    val visits: VisitRepository by lazy { RoomVisitRepository(database, onEnqueue = { coordinator?.requestSync() }) }
    val graphs: GraphRepository by lazy { RoomGraphRepository(database) }

    /** Tout ce que le mode courses lit et écrit (instantané du graphe compris). */
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

    val livePreferences: LiveUpdatePreferences by lazy { SharedPreferencesLiveUpdatePreferences(context) }

    /** Live Update du mode courses : **une seule instance** par processus, pour l'écran comme pour le receiver. */
    val liveUpdates: ShoppingLiveUpdates by lazy {
        ShoppingLiveUpdates(
            notifier = SystemLiveUpdateNotifier(context),
            visits = visits,
            lists = lists,
            analyzer = analyzer,
            preferences = livePreferences,
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Default),
            remaps = engine?.remaps ?: emptyFlow(),
        )
    }

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
     * aucune, ses introuvables remis à acheter : voir `VisitRepository.abandonVisit`) et rien n'est rouvert.
     * L'abandon ne lève rien sur une visite disparue entre-temps (reprise de compte) : le lancement ne plante pas,
     * et une visite redevenue active entre la lecture et l'abandon reste ouverte.
     */
    suspend fun resumableVisit(expiry: Duration = ShoppingTimings().expiry): ResumableVisit? {
        val visit = visits.openVisit() ?: return null
        val now = Clock.System.now()
        val last = visits.lastActivity(visit.id) ?: visit.startedAt
        val listExists = lists.list(visit.listId) != null
        val usable = listExists && now - last < expiry
        // Liste disparue : abandon sans condition. Sinon seulement si la visite est encore périmée dans la transaction.
        if (!usable) visits.abandonVisit(visit.id, now, staleAfter = if (listExists) expiry else Duration.ZERO)
        return if (usable) ResumableVisit(visit.listId, visit.storeId, visit.id) else null
    }

    /** Lancement : catégories, connexion anonyme, puis synchronisation (en tâche de fond). */
    fun start(scope: CoroutineScope) {
        scope.launch {
            categories.seedIfNeeded()
            // Une Live Update restée d'un lancement précédent ne survit que si sa visite est encore ouverte.
            liveUpdates.reconcile()
            gateway?.let { remote ->
                networkMonitor.start()
                coordinator?.start()
                // Un échec n'empêche rien : tout est local et la file attend.
                AuthBootstrap.signIn(remote)
                coordinator?.sessionDidChange()
            }
        }
    }

    /** Premier plan : une passe avec descente. */
    fun onForeground() {
        coordinator?.requestSync(pull = true)
    }

    private fun pulledItemClassifier(): (String) -> PulledItemClassification {
        val classifier = CategoryClassifier()
        return { label -> classifier.classify(label).let { PulledItemClassification(it.normalized, it.categoryId) } }
    }
}
