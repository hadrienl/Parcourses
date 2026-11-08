package fr.parcourses.core.data

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.data.sync.PulledItemClassification
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.SyncState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import kotlin.time.Duration
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Base en mémoire sous Robolectric, avec horloge et réseau pilotés par le test. */
abstract class DataTest {
    protected lateinit var db: ParcoursesDatabase
    protected var now: Instant = Instant.fromEpochSeconds(1_000_000)
    protected var online = true

    protected val dependencies = SyncDependencies(now = { now }, jitter = { 1.0 }, isOnline = { online })
    protected val classifier = CategoryClassifier()
    protected val classify: (String) -> PulledItemClassification = {
        classifier.classify(it).let { c -> PulledItemClassification(c.normalized, c.categoryId) }
    }

    @Before
    fun openDatabase() {
        db =
            ParcoursesDatabaseFactory.createInMemory(
                ApplicationProvider.getApplicationContext<Context>(),
                Dispatchers.IO,
                AndroidSQLiteDriver(),
            )
        runBlocking { db.categories().seedIfNeeded(CategorySeed.bundled()) }
    }

    @After
    fun closeDatabase() {
        db.close()
    }

    protected fun advance(duration: Duration) {
        now += duration
    }

    protected fun id(): String = Uuid.random().toString()

    protected suspend fun insertList(
        id: String = id(),
        state: SyncState = SyncState.PENDING,
    ): ShoppingListEntity = ShoppingListEntity(id, "Liste", now, now, syncState = state).also { db.lists().upsert(it) }

    protected suspend fun insertItem(
        listId: String,
        id: String = id(),
        label: String = "lait",
        productId: String? = null,
        state: SyncState = SyncState.PENDING,
        position: Int = 0,
    ): ListItemEntity =
        ListItemEntity(
            id = id,
            listId = listId,
            label = label,
            normalizedName = label,
            productId = productId,
            categoryId = "dairy",
            position = position,
            updatedAt = now,
            syncState = state,
        ).also { db.items().upsert(it) }
}
