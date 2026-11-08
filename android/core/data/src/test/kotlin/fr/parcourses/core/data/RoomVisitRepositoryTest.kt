package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.repository.RepositoryException
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

@RunWith(AndroidJUnit4::class)
@Suppress("LargeClass")
class RoomVisitRepositoryTest : DataTest() {
    private var wakeUps = 0
    private val visits by lazy { RoomVisitRepository(db, onEnqueue = { wakeUps++ }) }
    private val lists by lazy { RoomListRepository(db) }
    private val gateway = FakeRemoteGateway()
    private val engine by lazy { SyncEngine(gateway, db, InMemorySyncCursors(), classify, dependencies) }
    private val store = id()

    private suspend fun kinds() = db.outbox().pending().map { it.kind() }

    private suspend fun newList() = lists.createList("Courses", now)

    // region Ouverture

    @Test
    fun startingAVisitStaysLocalUntilTheFirstCheck() =
        runBlocking {
            val list = newList()
            db.outbox().all().forEach { db.outbox().delete(it.id) }
            val visit = visits.startVisit(store, list.id, listWasSorted = true, at = now)
            assertEquals(visit, visits.openVisit())
            assertTrue(visit.listWasSorted)
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun startingTwiceForTheSameStoreAndListReturnsTheOpenVisit() =
        runBlocking {
            val list = newList()
            val first = visits.startVisit(store, list.id, false, now)
            val second = visits.startVisit(store, list.id, true, now + 1.minutes)
            assertEquals(first.id, second.id)
            assertEquals(1, db.visits().getAll().size)
        }

    @Test
    fun startingAnotherVisitClosesTheOpenOneThatHasChecks() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val first = visits.startVisit(store, list.id, false, now)
            visits.checkItem(first.id, item.id, CheckSubject.Category("dairy"), now)
            val second = visits.startVisit(id(), list.id, false, now + 5.minutes)
            assertEquals(second.id, visits.openVisit()?.id)
            assertEquals(now + 5.minutes, visits.visit(first.id)?.endedAt)
            assertTrue(OutboxKind.CloseVisit in kinds())
        }

    @Test
    fun startingAnotherVisitDropsTheOpenOneWithoutChecks() =
        runBlocking {
            val list = newList()
            val first = visits.startVisit(store, list.id, false, now)
            visits.startVisit(id(), list.id, false, now + 5.minutes)
            assertNull(visits.visit(first.id))
            assertEquals(1, db.visits().getAll().size)
        }

    // endregion

    // region Coches

    @Test
    fun checkingWritesTheCheckTheItemAndTheQueueTogether() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", "2", null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            advance(10.seconds)
            val check = visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now, sendAfter = 5.seconds)

            assertEquals("dairy", check.categoryId)
            assertNull(check.productId)
            assertEquals(now, db.items().get(item.id)?.checkedAt)
            // list_items.checked_at part en plus de la coche.
            val pending = db.outbox().pending()
            assertTrue(OutboxKind.UpsertItem in pending.map { it.kind() })
            assertEquals(
                listOf(OutboxKind.CreateVisit, OutboxKind.InsertChecks),
                pending
                    .filter {
                        it.kind() in
                            setOf(
                                OutboxKind.CreateVisit,
                                OutboxKind.InsertChecks,
                            )
                    }.map { it.kind() },
            )
            // Retenues le temps de l'annulation.
            pending
                .filter { it.kind() == OutboxKind.CreateVisit || it.kind() == OutboxKind.InsertChecks }
                .forEach { assertEquals(now + 5.seconds, it.nextAttemptAt) }
            assertTrue(wakeUps > 0)
        }

    @Test
    fun aProductCheckKeepsTheProductNotTheCategory() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            val product = id()
            val check = visits.checkItem(visit.id, item.id, CheckSubject.Product(product), now)
            assertEquals(product, check.productId)
            assertNull(check.categoryId)
        }

    @Test
    fun onlyTheFirstCheckQueuesTheVisitCreation() =
        runBlocking {
            val list = newList()
            val a = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val b = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, a.id, CheckSubject.Category("dairy"), now)
            visits.checkItem(visit.id, b.id, CheckSubject.Category("bakery"), now + 1.seconds)
            assertEquals(1, kinds().count { it == OutboxKind.CreateVisit })
            assertEquals(2, kinds().count { it == OutboxKind.InsertChecks })
            assertEquals(2, visits.checks(visit.id).size)
        }

    @Test
    fun aClosedVisitRefusesChecks() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
            visits.closeVisit(visit.id, now + 1.minutes)
            try {
                visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
                fail()
            } catch (expected: RepositoryException.VisitClosed) {
                assertEquals(visit.id, expected.id)
            }
        }

    @Test
    fun aDeletedListRefusesChecks() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            lists.deleteList(list.id, now)
            try {
                visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
                fail()
            } catch (expected: RepositoryException.ListDeleted) {
                assertEquals(list.id, expected.id)
            }
        }

    // endregion

    // region Annulation

    @Test
    fun uncheckingAnUnsentCheckRemovesItAndTheVisitCreation() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            val check = visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now, sendAfter = 5.seconds)

            visits.uncheckItem(item.id, check.id, now + 1.seconds)

            assertNull(db.items().get(item.id)?.checkedAt)
            assertTrue(visits.checks(visit.id).isEmpty())
            assertFalse(OutboxKind.InsertChecks in kinds())
            // Sans autre coche, la visite ne partirait que vide.
            assertFalse(OutboxKind.CreateVisit in kinds())
            // L'article décoché part, lui, avec sa nouvelle valeur.
            assertTrue(OutboxKind.UpsertItem in kinds())
        }

    @Test
    fun uncheckingKeepsTheVisitCreationWhenAnotherCheckRemains() =
        runBlocking {
            val list = newList()
            val a = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val b = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, a.id, CheckSubject.Category("dairy"), now, 5.seconds)
            val second = visits.checkItem(visit.id, b.id, CheckSubject.Category("bakery"), now, 5.seconds)
            visits.uncheckItem(b.id, second.id, now)
            assertTrue(OutboxKind.CreateVisit in kinds())
            assertEquals(1, kinds().count { it == OutboxKind.InsertChecks })
        }

    @Test
    fun aCheckAlreadySentCannotBeRemoved() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            val check = visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
            assertNull(engine.drain())
            assertEquals(SyncState.SYNCED, db.checks().get(check.id)?.syncState)

            assertFalse(visits.removeCheck(check.id))
            visits.uncheckItem(item.id, check.id, now + 1.seconds)

            // Seule la liste change : la coche reste, le serveur ne sait pas la retirer.
            assertNotNull(db.checks().get(check.id))
            assertNull(db.items().get(item.id)?.checkedAt)
        }

    // endregion

    // region Clôture

    @Test
    fun closingWithoutAnyCheckDeletesTheVisitAndSendsNothing() =
        runBlocking {
            val list = newList()
            db.outbox().all().forEach { db.outbox().delete(it.id) }
            val visit = visits.startVisit(store, list.id, false, now)
            assertFalse(visits.closeVisit(visit.id, now + 1.minutes))
            assertNull(visits.visit(visit.id))
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun closingQueuesTheClosureAfterTheChecksAndIsIdempotent() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
            assertTrue(visits.closeVisit(visit.id, now + 1.minutes))
            assertTrue(visits.closeVisit(visit.id, now + 9.minutes))

            assertEquals(now + 1.minutes, visits.visit(visit.id)?.endedAt)
            assertEquals(1, kinds().count { it == OutboxKind.CloseVisit })
            assertNull(visits.openVisit())
        }

    @Test
    fun closingAnUnknownVisitFails() =
        runBlocking {
            try {
                visits.closeVisit(id(), now)
                fail()
            } catch (expected: RepositoryException.NotFound) {
                assertNotNull(expected.id)
            }
        }

    // endregion

    // region Envoi

    @Test
    fun aFullVisitLeavesInOrderVisitChecksThenClosure() =
        runBlocking {
            val list = newList()
            val a = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val b = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, true, now)
            val first = visits.checkItem(visit.id, a.id, CheckSubject.Category("dairy"), now + 1.seconds)
            val second = visits.checkItem(visit.id, b.id, CheckSubject.Category("bakery"), now + 2.seconds)
            visits.closeVisit(visit.id, now + 3.seconds)
            advance(10.seconds)

            assertNull(engine.drain())

            val calls =
                gateway.calls.filter {
                    it.substringBefore(':') in
                        setOf("createVisit", "insertChecks", "closeVisit")
                }
            // Les deux coches partent en un seul lot.
            assertEquals(listOf("createVisit:${visit.id}", "insertChecks:2", "closeVisit:${visit.id}"), calls)
            assertEquals(
                setOf(first.id, second.id),
                gateway.savedChecks
                    .flatten()
                    .map { it.id.toString() }
                    .toSet(),
            )
            assertEquals(SyncState.SYNCED, db.visits().get(visit.id)?.syncState)
            assertEquals(SyncState.SYNCED, db.visits().get(visit.id)?.endSyncState)
            assertTrue(db.outbox().all().isEmpty())
        }

    @Test
    fun anUndoneCheckIsNeverSentButTheRestIs() =
        runBlocking {
            val list = newList()
            val a = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val b = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, a.id, CheckSubject.Category("dairy"), now, sendAfter = 5.seconds)
            val undone = visits.checkItem(visit.id, b.id, CheckSubject.Category("bakery"), now, sendAfter = 5.seconds)
            visits.uncheckItem(b.id, undone.id, now)

            // Pendant l'annulation, rien ne part.
            advance(2.seconds)
            engine.drain()
            assertTrue(gateway.callsOf("insertChecks").isEmpty())

            advance(10.seconds)
            engine.drain()
            assertEquals(1, gateway.savedChecks.flatten().size)
            assertFalse(gateway.savedChecks.flatten().any { it.id.toString() == undone.id })
        }

    // endregion
}
