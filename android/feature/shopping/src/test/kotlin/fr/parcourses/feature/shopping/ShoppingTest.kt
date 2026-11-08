package fr.parcourses.feature.shopping

import android.content.Context
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomGraphRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomStoreRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import java.lang.reflect.Proxy
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Passerelle simulée : seuls le rayon bio et l'instantané du graphe répondent. */
class FakeSnapshotGateway(
    var snapshot: suspend () -> GraphSnapshotResponse = { GraphSnapshotResponse.None },
    var organic: suspend () -> Boolean? = { null },
) : RemoteGateway by unsupported() {
    var snapshotCalls = 0
    var knownVersions = mutableListOf<Long?>()

    override suspend fun storeOrganicAisle(id: Uuid): Boolean? = organic()

    override suspend fun graphSnapshot(
        storeId: Uuid,
        knownVersion: Long?,
    ): GraphSnapshotResponse {
        snapshotCalls++
        knownVersions += knownVersion
        return snapshot()
    }

    private companion object {
        fun unsupported(): RemoteGateway =
            Proxy.newProxyInstance(
                RemoteGateway::class.java.classLoader,
                arrayOf(RemoteGateway::class.java),
            ) { _, method, _ -> throw UnsupportedOperationException(method.name) } as RemoteGateway
    }
}

/**
 * Vraies couches Room sous Robolectric (requêtes exécutées en ligne sur le fil du test), temps virtuel : les
 * délais du mode courses (600 ms, 4 s, 45 min) se pilotent sans attendre.
 */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class ShoppingTest {
    protected val scheduler = TestCoroutineScheduler()
    protected val main = StandardTestDispatcher(scheduler)
    protected lateinit var db: ParcoursesDatabase
    protected lateinit var lists: RoomListRepository
    protected lateinit var visits: RoomVisitRepository
    protected lateinit var graphs: RoomGraphRepository
    protected lateinit var stores: RoomStoreRepository
    protected val analyzer = EntryAnalyzer()
    protected val storeId: String = Uuid.random().toString()
    protected var gateway: FakeSnapshotGateway? = FakeSnapshotGateway()

    /** Temps écoulé hors du temps virtuel : fait « passer 45 min » sans les attendre. */
    protected var offset: Duration = Duration.ZERO

    protected val clock: () -> Instant = { BASE + scheduler.currentTime.milliseconds + offset }

    @Before
    fun setUp() {
        Dispatchers.setMain(main)
        db =
            ParcoursesDatabaseFactory.createInMemory(
                ApplicationProvider.getApplicationContext<Context>(),
                Dispatchers.Unconfined,
                AndroidSQLiteDriver(),
            )
        lists = RoomListRepository(db)
        visits = RoomVisitRepository(db)
        graphs = RoomGraphRepository(db)
        stores = RoomStoreRepository(db)
        runBlocking {
            RoomCategoryRepository(db).seedIfNeeded()
            stores.upsertStore(storeId, "Carrefour", null, null, organicAisle = false)
        }
    }

    /** Les modèles du test : vidés avant la base, sinon leurs collectes Room continueraient sur une base fermée. */
    protected val viewModels = ViewModelStore()

    @After
    fun tearDown() {
        viewModels.clear()
        scheduler.runCurrent()
        db.close()
        Dispatchers.resetMain()
    }

    /** Crée un modèle rattaché à [viewModels], comme le ferait une entrée de navigation. */
    protected fun tracked(make: () -> ShoppingViewModel): ShoppingViewModel =
        ViewModelProvider.create(viewModels, viewModelFactory { initializer { make() } })[
            Uuid.random().toString(),
            ShoppingViewModel::class,
        ]

    protected fun deps() =
        ShoppingDependencies(
            lists = lists,
            visits = visits,
            stores = stores,
            categories = RoomCategoryRepository(db),
            analyzer = analyzer,
            cache = GraphSnapshotCache(graphs, gateway, clock),
        )

    protected fun model(
        listId: String,
        store: String? = storeId,
        remaps: Flow<IdentifierRemap> = emptyFlow(),
        timings: ShoppingTimings = ShoppingTimings(),
    ) = tracked {
        ShoppingViewModel(
            listId = listId,
            storeId = store,
            deps = deps(),
            remaps = remaps,
            timings = timings,
            now = clock,
            computation = main,
        )
    }

    protected suspend fun newList(vararg items: Triple<String, String, String?>): Pair<String, List<ListItemEntity>> {
        val list = lists.createList("Courses", clock())
        return list.id to
            items.map { (label, category, product) ->
                val entry = analyzer.analyze(label)
                lists.addItem(list.id, entry.label, entry.normalizedName, entry.quantity, product, category, clock())
            }
    }

    protected suspend fun TestScope.started(model: ShoppingViewModel): ShoppingUiState {
        model.start()
        runCurrent()
        return model.uiState.value
    }

    protected suspend fun TestScope.after(ms: Long) {
        advanceTimeBy(ms)
        runCurrent()
    }

    protected fun ShoppingUiState.row(label: String): ShoppingRow =
        (toBuy + basket + notFound).first { it.label == label }

    protected fun ShoppingUiState.labels() = toBuy.map { it.label }

    /** Instantané appris : l'entrée du magasin mène à [products], dans cet ordre. */
    protected fun learnedPayload(
        vararg products: String,
        confidenceQ: Int = 800,
        version: Long = 5,
    ): String {
        val entry = """{"product_id":"${products.first()}","weight_q":1000}"""
        val edges =
            products.toList().zipWithNext().joinToString(",") { (a, b) ->
                val (low, high) = if (a < b) a to b else b to a
                """{"a":"$low","b":"$high","weight_q":1000}"""
            }
        return """{"format_version":1,"snapshot_version":$version,"params_version":1,
            |"params":{"CONF_THRESHOLD_Q":500,"COST_SCALE":1000,"UNKNOWN_BASE":3000,"CAT_STEP":200,
            |"TWO_OPT_MAX_PASSES":20,"REORDER_MIN_GAIN_PCT":10},
            |"confidence_q":$confidenceQ,"entries":[$entry],"edges":[$edges]}
            """.trimMargin()
    }

    protected suspend fun cacheSnapshot(payload: String) {
        graphs.saveSnapshot(storeId, 5, 1, 800, payload.encodeToByteArray(), clock())
    }

    protected fun hanging(): CompletableDeferred<GraphSnapshotResponse> = CompletableDeferred()

    protected companion object {
        val BASE: Instant = Instant.fromEpochSeconds(1_800_000_000)
        const val P1 = "00000000-0000-0000-0000-000000000001"
        const val P2 = "00000000-0000-0000-0000-000000000002"
        const val P3 = "00000000-0000-0000-0000-000000000003"
    }
}
