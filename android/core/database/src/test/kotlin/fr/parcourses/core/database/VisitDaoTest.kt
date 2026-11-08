package fr.parcourses.core.database

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.GraphSnapshotEntity
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.database.entity.VisitEntity
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class VisitDaoTest : DatabaseTest() {
    private fun visit(
        id: String,
        startedAt: Long = 0,
    ) = VisitEntity(id = id, storeId = "s", listId = "l", listWasSorted = true, startedAt = at(startedAt))

    private fun check(
        id: String,
        visitId: String,
        checkedAt: Long,
        productId: String? = "p-$id",
        categoryId: String? = null,
    ) = CheckEntity(
        id = id,
        visitId = visitId,
        itemId = "i-$id",
        productId = productId,
        categoryId = categoryId,
        checkedAt = at(checkedAt),
    )

    @Test
    fun closeIsIdempotentAndKeepsTheFirstEndedAt() =
        runBlocking {
            db.visits().upsert(visit("v"))
            assertEquals(1, db.visits().close("v", at(100)))
            assertEquals(0, db.visits().close("v", at(200)))
            val closed = db.visits().get("v")!!
            assertEquals(at(100), closed.endedAt)
            assertEquals(SyncState.PENDING, closed.endSyncState)
        }

    @Test
    fun openVisitsExcludeClosedOnes() =
        runBlocking {
            db.visits().upsert(visit("old", startedAt = 1))
            db.visits().upsert(visit("recent", startedAt = 2))
            db.visits().upsert(visit("done", startedAt = 3))
            db.visits().close("done", at(4))
            assertEquals(listOf("recent", "old"), db.visits().getOpen().map { it.id })
        }

    @Test
    fun creationAndClosureHaveIndependentSyncStates() =
        runBlocking {
            db.visits().upsert(visit("v"))
            db.visits().setSyncState("v", SyncState.SYNCED)
            val v = db.visits().get("v")!!
            assertEquals(SyncState.SYNCED, v.syncState)
            assertEquals(SyncState.PENDING, v.endSyncState)
        }

    @Test
    fun checksAreOrderedByTimeAndLatestForItemWins() =
        runBlocking {
            db.checks().upsert(check("b", "v", 20))
            db.checks().upsert(check("a", "v", 10))
            db.checks().upsert(check("c", "other", 5, productId = null, categoryId = "dairy"))
            assertEquals(listOf("a", "b"), db.checks().getByVisit("v").map { it.id })
            assertEquals("c", db.checks().latestForItem("i-c")?.id)
            assertEquals(2, db.checks().deleteByVisit("v"))
            assertNull(db.checks().get("a"))
        }

    @Test
    fun recentStoresAreOrderedByLastUse() =
        runBlocking {
            db.stores().upsert(StoreEntity("a", "A"))
            db.stores().upsert(StoreEntity("b", "B", lastUsedAt = at(1), organicAisle = true))
            db.stores().upsert(StoreEntity("c", "C"))
            db.stores().markUsed("c", at(5))
            assertEquals(listOf("c", "b"), db.stores().recent(10).map { it.id })
            assertEquals(listOf("c"), db.stores().recent(1).map { it.id })
            assertFalse(db.stores().get("a")!!.organicAisle)
        }

    @Test
    fun graphSnapshotIsReplacedAndOnlyTheNewestFiveAreKept() =
        runBlocking {
            for (n in 1..7) {
                db.graphSnapshots().upsert(GraphSnapshotEntity("s$n", 1, 1, 100, at(n.toLong()), byteArrayOf(n.toByte())))
                db.graphSnapshots().trim(5)
            }
            assertEquals(listOf("s7", "s6", "s5", "s4", "s3"), db.graphSnapshots().getAll().map { it.storeId })

            db.graphSnapshots().upsert(GraphSnapshotEntity("s7", 2, 1, 100, at(8), byteArrayOf(9, 9)))
            val replaced = db.graphSnapshots().get("s7")!!
            assertEquals(2L, replaced.snapshotVersion)
            assertArrayEquals(byteArrayOf(9, 9), replaced.payload)
            assertEquals(5, db.graphSnapshots().getAll().size)
        }
}
