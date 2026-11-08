package fr.parcourses.core.database

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OutboxDaoTest : DatabaseTest() {
    private val payload = "{}".toByteArray()

    @Test
    fun sequenceGrowsAndDefinesTheProcessingOrder() =
        runBlocking {
            val dao = db.outbox()
            // `createdAt` est inversé exprès : seule `sequence` compte.
            dao.enqueue("e1", OutboxKind.UpsertList, "l", payload, at(30))
            dao.enqueue("e2", OutboxKind.UpsertItem, "i", payload, at(20))
            dao.enqueue("e3", OutboxKind.CloseVisit, "v", payload, at(10))
            assertEquals(listOf("e1", "e2", "e3"), dao.pending().map { it.id })
            assertEquals(listOf(1L, 2L, 3L), dao.pending().map { it.sequence })
        }

    @Test
    fun replacementKeepsTheRankOfTheCancelledEntry() =
        runBlocking {
            val dao = db.outbox()
            dao.enqueue("list-1", OutboxKind.UpsertList, "l", payload, at(1))
            dao.enqueue("item-1", OutboxKind.UpsertItem, "i", payload, at(2))

            val kept = dao.cancelPending("l", setOf(OutboxKind.UpsertList))
            assertEquals(1L, kept)
            dao.enqueue("list-2", OutboxKind.UpsertList, "l", payload, at(3), keepingSequence = kept)

            // La liste renommée passe toujours avant son article.
            assertEquals(listOf("list-2", "item-1"), dao.pending().map { it.id })
        }

    @Test
    fun cancelOnlyTouchesThePendingEntriesOfThatKind() =
        runBlocking {
            val dao = db.outbox()
            dao.enqueue("a", OutboxKind.UpsertItem, "i", payload, at(1))
            dao.enqueue("b", OutboxKind.DeleteItem, "i", payload, at(2))
            assertNull(dao.cancelPending("other", setOf(OutboxKind.UpsertItem)))
            dao.cancelPending("i", setOf(OutboxKind.UpsertItem))
            assertEquals(listOf("b"), dao.all().map { it.id })
        }

    @Test
    fun dueEntriesRespectNextAttemptAndNotBefore() =
        runBlocking {
            val dao = db.outbox()
            dao.enqueue("now", OutboxKind.InsertChecks, "c1", payload, at(10))
            // Coche retenue le temps de l'annulation (#9.9).
            dao.enqueue("held", OutboxKind.InsertChecks, "c2", payload, at(10), notBefore = at(15))
            assertEquals(listOf("now"), dao.due(at(12)).map { it.id })
            assertEquals(listOf("now", "held"), dao.due(at(15)).map { it.id })
        }

    @Test
    fun failedEntriesAreNotReplayed() =
        runBlocking {
            val dao = db.outbox()
            dao.enqueue("a", OutboxKind.CreateVisit, "v", payload, at(1))
            dao.recordAttempt("a", 3, at(99), "23503", at(50), SyncState.FAILED)
            assertEquals(emptyList<String>(), dao.due(at(1000)).map { it.id })
            val stored = dao.all().single()
            assertEquals(3, stored.attempts)
            assertEquals("23503", stored.lastError)
            assertEquals(at(50), stored.serverFailingSince)
            assertEquals(0, dao.pendingCount())
        }

    @Test
    fun unknownKindReadsAsNullInsteadOfFailing() =
        runBlocking {
            val dao = db.outbox()
            dao.enqueue("a", OutboxKind.CloseVisit, "v", payload, at(1))
            val entry = dao.all().single()
            assertEquals(OutboxKind.CloseVisit, entry.kind())
            assertNull(entry.copy(kindRaw = "fromTheFuture").kind())
        }
}
