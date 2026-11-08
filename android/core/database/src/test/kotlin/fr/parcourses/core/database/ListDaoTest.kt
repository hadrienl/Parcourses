package fr.parcourses.core.database

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.entity.SyncState
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListDaoTest : DatabaseTest() {
    @Test
    fun activeListsAreSortedByMostRecentlyUpdated() =
        runBlocking {
            db.lists().upsert(list("a", updatedAt = 10))
            db.lists().upsert(list("b", updatedAt = 30))
            db.lists().upsert(list("c", updatedAt = 20))
            assertEquals(listOf("b", "c", "a"), db.lists().observeActive().first().map { it.id })
        }

    @Test
    fun softDeletedListLeavesActiveListsButStaysInDatabase() =
        runBlocking {
            db.lists().upsert(list("a"))
            db.lists().markDeleted("a", at(5))
            assertEquals(emptyList<String>(), db.lists().observeActive().first().map { it.id })
            val kept = db.lists().get("a")
            assertNotNull(kept?.deletedAt)
            assertEquals(SyncState.PENDING, kept?.syncState)
        }

    @Test
    fun renameMarksPendingAndTouchesUpdatedAt() =
        runBlocking {
            db.lists().upsert(list("a").copy(syncState = SyncState.SYNCED))
            assertEquals(1, db.lists().rename("a", "Courses", at(9)))
            val renamed = db.lists().get("a")!!
            assertEquals("Courses", renamed.name)
            assertEquals(at(9), renamed.updatedAt)
            assertEquals(SyncState.PENDING, renamed.syncState)
        }

    @Test
    fun observeEmitsAgainAfterAWrite() =
        runBlocking {
            db.lists().upsert(list("a"))
            val first = db.lists().observeActive().first()
            db.lists().upsert(list("b", updatedAt = 1))
            val second = db.lists().observeActive().first()
            assertEquals(1, first.size)
            assertEquals(2, second.size)
        }

    @Test
    fun itemsAreOrderedByPositionAndNextPositionFollowsTheLast() =
        runBlocking {
            db.lists().upsert(list("l"))
            assertEquals(0, db.items().nextPosition("l"))
            db.items().upsertAll(listOf(item("x", "l", 2), item("y", "l", 0), item("z", "l", 1)))
            assertEquals(listOf("y", "z", "x"), db.items().getByList("l").map { it.id })
            assertEquals(listOf("y", "z", "x"), db.items().observeByList("l").first().map { it.id })
            assertEquals(3, db.items().nextPosition("l"))
        }

    @Test
    fun checkedUpdatesTheItemAndNotFoundStaysLocal() =
        runBlocking {
            db.lists().upsert(list("l"))
            db.items().upsert(item("x", "l", 0).copy(syncState = SyncState.SYNCED))

            db.items().setNotFound("x", at(7))
            val notFound = db.items().get("x")!!
            assertEquals(at(7), notFound.notFoundAt)
            assertEquals(SyncState.SYNCED, notFound.syncState)
            assertEquals(at(0), notFound.updatedAt)

            db.items().setChecked("x", at(8), at(9))
            val checked = db.items().get("x")!!
            assertEquals(at(8), checked.checkedAt)
            assertEquals(at(9), checked.updatedAt)
            assertEquals(SyncState.PENDING, checked.syncState)
        }

    @Test
    fun itemHistoryIgnoresDeletedListsAndNewestComeFirst() =
        runBlocking {
            db.lists().upsert(list("live"))
            db.lists().upsert(list("gone"))
            db.items().upsert(item("old", "live", 0).copy(updatedAt = at(1)))
            db.items().upsert(item("new", "live", 1).copy(updatedAt = at(2)))
            db.items().upsert(item("hidden", "gone", 0))
            db.lists().markDeleted("gone", at(3))
            assertEquals(listOf("new", "old"), db.items().itemHistory().map { it.id })
        }

    @Test
    fun deleteByListRemovesOnlyItsItems() =
        runBlocking {
            db.lists().upsert(list("a"))
            db.lists().upsert(list("b"))
            db.items().upsertAll(listOf(item("1", "a", 0), item("2", "b", 0)))
            assertEquals(1, db.items().deleteByList("a"))
            assertNull(db.items().get("1"))
            assertNotNull(db.items().get("2"))
        }
}
