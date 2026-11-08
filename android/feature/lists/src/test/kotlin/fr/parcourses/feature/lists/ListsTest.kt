package fr.parcourses.feature.lists

import android.content.Context
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.runtime.snapshots.Snapshot
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.RoomCategoryRepository
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomProductRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Before
import kotlin.time.Instant

/** Vraies couches Room sous Robolectric : les modèles sont testés avec leurs repositories. */
@OptIn(ExperimentalCoroutinesApi::class)
abstract class ListsTest {
    protected lateinit var db: ParcoursesDatabase
    protected lateinit var lists: RoomListRepository
    protected val analyzer = EntryAnalyzer()
    protected var clock: Instant = Instant.fromEpochSeconds(1_000_000)
    protected var wakeUps = 0

    @Before
    fun setUp() {
        Dispatchers.setMain(Dispatchers.Unconfined)
        db =
            ParcoursesDatabaseFactory.createInMemory(
                ApplicationProvider.getApplicationContext<Context>(),
                Dispatchers.IO,
                AndroidSQLiteDriver(),
            )
        lists = RoomListRepository(db, onEnqueue = { wakeUps++ })
        runBlocking { RoomCategoryRepository(db).seedIfNeeded() }
    }

    @After
    fun tearDown() {
        db.close()
        Dispatchers.resetMain()
    }

    protected fun listsModel() = ListsViewModel(lists) { clock }

    protected fun detailModel(
        listId: String,
        remaps: Flow<IdentifierRemap> = emptyFlow(),
    ) = ListDetailViewModel(
        listId = listId,
        lists = lists,
        products = RoomProductRepository(db),
        categories = RoomCategoryRepository(db),
        analyzer = analyzer,
        remaps = remaps,
        now = { clock },
        computation = Dispatchers.Unconfined,
    )

    /**
     * Saisit du texte. Hors Compose, rien n'applique les écritures de l'état global : `snapshotFlow` (suggestions)
     * ne les verrait pas sans cet appel, que Compose fait lui-même en vrai.
     */
    protected fun ListDetailViewModel.type(text: String) {
        input.setTextAndPlaceCursorAtEnd(text)
        Snapshot.sendApplyNotifications()
    }

    /** Attend (au plus 5 s) que l'état réponde au prédicat : Room répond sur ses propres threads. */
    protected fun <T> StateFlow<T>.await(predicate: (T) -> Boolean): T =
        runBlocking { withTimeout(AWAIT_MS) { first(predicate) } }

    private companion object {
        const val AWAIT_MS = 5_000L
    }
}
