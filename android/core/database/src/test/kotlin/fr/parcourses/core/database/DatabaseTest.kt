package fr.parcourses.core.database

import android.content.Context
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import kotlinx.coroutines.Dispatchers
import org.junit.After
import org.junit.Before
import kotlin.time.Instant

/** Base en mémoire sous Robolectric (SQLite du système simulé), recréée à chaque test. */
abstract class DatabaseTest {
    protected lateinit var db: ParcoursesDatabase

    @Before
    fun openDatabase() {
        db =
            ParcoursesDatabaseFactory.createInMemory(
                ApplicationProvider.getApplicationContext<Context>(),
                Dispatchers.IO,
                AndroidSQLiteDriver(),
            )
    }

    @After
    fun closeDatabase() {
        db.close()
    }

    protected fun at(seconds: Long): Instant = Instant.fromEpochSeconds(seconds)

    protected fun list(
        id: String,
        updatedAt: Long = 0,
    ) = ShoppingListEntity(id = id, name = "Liste $id", createdAt = at(0), updatedAt = at(updatedAt))

    protected fun item(
        id: String,
        listId: String,
        position: Int,
        categoryId: String = "other",
    ) = ListItemEntity(
        id = id,
        listId = listId,
        label = "Article $id",
        normalizedName = "article $id",
        categoryId = categoryId,
        position = position,
        updatedAt = at(0),
    )
}
