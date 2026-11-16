package fr.parcourses.feature.lists

import android.content.Context
import android.os.Looper
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.snapshots.Snapshot
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.TestDispatcher
import org.junit.After
import org.junit.Before
import org.robolectric.Shadows.shadowOf
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Vraies couches Room sous Robolectric : les modèles sont testés avec leurs repositories.
 *
 * Le fil du test est le fil principal, comme en vrai : `Dispatchers.Main` reste celui d'Android (le looper principal de
 * Robolectric), sans `setMain`. Une écriture Room finie sur `Dispatchers.IO` ne reprend sur le fil principal que
 * lorsque le test le fait tourner ([pumpMain]), jamais en même temps qu'une action du test (#113). Avec
 * `Dispatchers.Unconfined`, ces reprises tournaient sur les fils d'IO, en parallèle du test et parfois après lui.
 */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class ListsTest {
    protected lateinit var db: ParcoursesDatabase
    protected lateinit var lists: RoomListRepository
    protected val analyzer = EntryAnalyzer()
    protected var clock: Instant = Instant.fromEpochSeconds(1_000_000)
    protected var wakeUps = 0

    @Before
    fun setUp() {
        db =
            ParcoursesDatabaseFactory.createInMemory(
                ApplicationProvider.getApplicationContext<Context>(),
                Dispatchers.IO,
                AndroidSQLiteDriver(),
            )
        lists = RoomListRepository(db, onEnqueue = { wakeUps++ })
        runBlocking { RoomCategoryRepository(db).seedIfNeeded() }
    }

    /**
     * Les modèles du test, vidés avant la fermeture de la base : sinon leurs collectes Room continuent pendant le
     * test suivant, sur une base fermée.
     */
    protected val viewModels = ViewModelStore()

    /** Les tâches de fond des modèles, attendues avant la fermeture de la base. */
    protected val modelJobs = mutableListOf<Job>()

    /** Répartiteurs de test passés aux modèles : ils tournent aussi pendant l'arrêt des modèles. */
    protected val testDispatchers = mutableListOf<TestDispatcher>()

    @After
    fun tearDown() {
        viewModels.clear()
        // Une écriture non annulable (ajout d'article) se termine même modèle vidé : la base reste ouverte jusque-là.
        pumpMain(
            "fin des tâches des modèles",
            step = { testDispatchers.forEach { it.scheduler.runCurrent() } },
        ) { modelJobs.all { it.isCompleted } }
        // `setUp` a pu échouer avant d'ouvrir la base : son erreur reste celle qu'on voit.
        if (::db.isInitialized) db.close()
    }

    /** Crée un modèle rattaché à [viewModels], comme le ferait une entrée de navigation. */
    protected inline fun <reified T : ViewModel> tracked(noinline make: () -> T): T {
        val factory = viewModelFactory { initializer { make() } }
        val model = ViewModelProvider.create(viewModels, factory)[Uuid.random().toString(), T::class]
        modelJobs += model.viewModelScope.coroutineContext.job
        return model
    }

    protected fun listsModel() = tracked { ListsViewModel(lists) { clock } }

    protected fun detailModel(
        listId: String,
        remaps: Flow<IdentifierRemap> = emptyFlow(),
    ) = tracked {
        ListDetailViewModel(
            listId = listId,
            lists = lists,
            products = RoomProductRepository(db),
            categories = RoomCategoryRepository(db),
            analyzer = analyzer,
            remaps = remaps,
            now = { clock },
            computation = Dispatchers.Unconfined,
        )
    }

    /**
     * Saisit du texte. Hors Compose, rien n'applique les écritures de l'état global : `snapshotFlow` (suggestions)
     * ne les verrait pas sans cet appel, que Compose fait lui-même en vrai.
     */
    protected fun ListDetailViewModel.type(text: String) {
        input.setTextAndPlaceCursorAtEnd(text)
        Snapshot.sendApplyNotifications()
    }

    /**
     * Attend (au plus 5 s) que l'état réponde au prédicat, en faisant tourner le fil principal : Room répond sur ses
     * propres fils, puis reprend sur le fil principal. Un abonné le suit pendant l'attente, comme un écran.
     */
    protected fun <T> StateFlow<T>.await(predicate: (T) -> Boolean): T {
        val found = CompletableDeferred<T>()
        val screen = CoroutineScope(Dispatchers.Main.immediate)
        screen.launch { found.complete(first(predicate)) }
        try {
            pumpMain("état attendu, dernier vu : $value") { found.isCompleted }
        } finally {
            screen.cancel()
        }
        return found.getCompleted()
    }

    /**
     * Fait tourner le fil principal (le fil du test) jusqu'à [done], au plus 5 s. [step] s'exécute à chaque tour,
     * avant le test de [done].
     */
    protected fun pumpMain(
        what: String,
        step: () -> Unit = {},
        done: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + AWAIT_NS
        while (true) {
            shadowOf(Looper.getMainLooper()).idle()
            step()
            if (done()) return
            check(System.nanoTime() < deadline) { "Délai dépassé : $what" }
            Thread.sleep(STEP_MS)
        }
    }

    private companion object {
        const val AWAIT_NS = 5_000_000_000L
        const val STEP_MS = 2L
    }
}
