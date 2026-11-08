package fr.parcourses.app

import android.content.Context
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.CategoryRepository
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.ProductRepository
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.repository.RoomStoreRepository
import fr.parcourses.core.data.repository.StoreRepository
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch

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

    private val storeChoiceEvents = MutableSharedFlow<StoreChoice>(extraBufferCapacity = 1)

    /**
     * Choix de magasin, un événement à consommation unique (sans rejeu) lié à sa liste : un choix ancien ne peut
     * pas rouvrir une visite. Le mode courses (A8) le collecte tant que l'app est ouverte.
     */
    val storeChoices: Flow<StoreChoice> = storeChoiceEvents.asSharedFlow()

    fun offerStoreChoice(choice: StoreChoice) {
        storeChoiceEvents.tryEmit(choice)
    }

    /** Lancement : catégories, connexion anonyme, puis synchronisation (en tâche de fond). */
    fun start(scope: CoroutineScope) {
        scope.launch {
            categories.seedIfNeeded()
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
