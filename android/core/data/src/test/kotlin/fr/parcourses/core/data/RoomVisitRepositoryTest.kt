package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.repository.RepositoryException
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.OutboxReconciliation
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.database.entity.VisitEntity
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Duration.Companion.hours
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
            // Close à sa dernière coche, pas au début de la suivante.
            assertEquals(now, visits.visit(first.id)?.endedAt)
            assertTrue(OutboxKind.CloseVisit in kinds())
        }

    @Test
    fun anotherListClosesTheOpenVisitAtItsLastCheckNotNow() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val first = visits.startVisit(store, list.id, false, now)
            visits.checkItem(first.id, item.id, CheckSubject.Category("dairy"), now + 2.minutes)
            val other = lists.createList("Autre", now)
            visits.startVisit(store, other.id, false, now + 3.hours)
            // La visite s'arrête à sa dernière coche : les trois heures passées ailleurs ne comptent pas.
            assertEquals(now + 2.minutes, visits.visit(first.id)?.endedAt)
        }

    @Test
    fun aStaleVisitIsClosedAtItsLastCheckAndReplaced() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val first = visits.startVisit(store, list.id, false, now)
            visits.checkItem(first.id, item.id, CheckSubject.Category("dairy"), now + 1.minutes)
            assertEquals(now + 1.minutes, visits.lastActivity(first.id))

            // Encore active : la même visite revient.
            assertEquals(first.id, visits.startVisit(store, list.id, false, now + 30.minutes, 45.minutes).id)
            // Plus de 45 min sans coche : close à sa dernière coche, une neuve commence.
            val fresh = visits.startVisit(store, list.id, false, now + 50.minutes, staleAfter = 45.minutes)
            assertTrue(fresh.id != first.id)
            assertEquals(now + 1.minutes, visits.visit(first.id)?.endedAt)
            assertEquals(now + 50.minutes, fresh.startedAt)
            assertEquals(fresh.id, visits.openVisit()?.id)
        }

    @Test
    fun theLastActivityOfAVisitWithoutChecksIsItsStart() =
        runBlocking {
            val list = newList()
            val visit = visits.startVisit(store, list.id, false, now)
            assertEquals(now, visits.lastActivity(visit.id))
            assertNull(visits.lastActivity(id()))
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

    // region Visite abandonnée (#54, M3)

    @Test
    fun aStaleVisitReplacedByAFreshOneLeavesNoNotFound() =
        runBlocking {
            val list = newList()
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val first = visits.startVisit(store, list.id, false, now)
            visits.checkItem(first.id, milk.id, CheckSubject.Category("dairy"), now + 1.minutes)
            lists.setNotFound(bread.id, now + 2.minutes)
            val before = db.items().get(bread.id)!!

            visits.startVisit(store, list.id, false, now + 60.minutes, staleAfter = 45.minutes)

            // Comme « garder » : le pain revient à acheter, sans rien envoyer pour autant (champ local).
            val after = db.items().get(bread.id)!!
            assertNull(after.notFoundAt)
            assertEquals(before.updatedAt, after.updatedAt)
            assertEquals(before.syncState, after.syncState)
            assertEquals(now + 1.minutes, visits.visit(first.id)?.endedAt)
        }

    @Test
    fun aVisitStillActiveKeepsItsNotFound() =
        runBlocking {
            val list = newList()
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val first = visits.startVisit(store, list.id, false, now)
            lists.setNotFound(bread.id, now + 1.minutes)

            assertEquals(first.id, visits.startVisit(store, list.id, false, now + 10.minutes, 45.minutes).id)
            assertEquals(now + 1.minutes, db.items().get(bread.id)?.notFoundAt)
        }

    @Test
    fun aVisitReplacedForAnotherListPutsItsOwnNotFoundBackAndNoOtherList() =
        runBlocking {
            val list = newList()
            val other = lists.createList("Apéro", now)
            val untouched = lists.createList("Bricolage", now)
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val chips = lists.addItem(other.id, "chips", "chips", null, null, "savory-grocery", now)
            val screws = lists.addItem(untouched.id, "vis", "vis", null, null, "other", now)
            lists.setNotFound(chips.id, now)
            lists.setNotFound(screws.id, now)
            val first = visits.startVisit(store, list.id, false, now)
            lists.setNotFound(bread.id, now + 1.minutes)
            // Introuvable puis trouvé quand même : coché, il garde son `notFoundAt`, comme avec « garder ».
            lists.setNotFound(milk.id, now + 1.minutes)
            visits.checkItem(first.id, milk.id, CheckSubject.Category("dairy"), now + 2.minutes)

            visits.startVisit(store, other.id, false, now + 5.minutes)

            assertNull(db.items().get(bread.id)?.notFoundAt)
            assertEquals(now + 1.minutes, db.items().get(milk.id)?.notFoundAt)
            assertNull(db.items().get(chips.id)?.notFoundAt)
            // Liste sans visite, ni close ni ouverte : son introuvable reste.
            assertEquals(now, db.items().get(screws.id)?.notFoundAt)
        }

    @Test
    fun aFreshVisitStartsWithoutTheNotFoundOfAVisitClosedWithoutDecision() =
        runBlocking {
            // Visite expirée (close à sa dernière coche) puis processus tué avant « garder » ou « retirer ».
            val list = newList()
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val first = visits.startVisit(store, list.id, false, now)
            visits.checkItem(first.id, milk.id, CheckSubject.Category("dairy"), now)
            lists.setNotFound(bread.id, now)
            visits.closeVisit(first.id, now)
            assertEquals(now, db.items().get(bread.id)?.notFoundAt)

            visits.startVisit(store, list.id, false, now + 2.hours)
            assertNull(db.items().get(bread.id)?.notFoundAt)
        }

    @Test
    fun abandoningAVisitClosesItAtItsLastCheckAndPutsTheNotFoundBack() =
        runBlocking {
            val list = newList()
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, milk.id, CheckSubject.Category("dairy"), now + 3.minutes)
            lists.setNotFound(bread.id, now + 4.minutes)
            wakeUps = 0

            assertTrue(visits.abandonVisit(visit.id, now + 2.hours, staleAfter = 45.minutes))

            assertEquals(now + 3.minutes, visits.visit(visit.id)?.endedAt)
            assertNull(db.items().get(bread.id)?.notFoundAt)
            assertTrue(OutboxKind.CloseVisit in kinds())
            assertEquals(1, wakeUps)
            assertNull(visits.openVisit())
        }

    @Test
    fun aVisitActiveAgainIsNotAbandoned() =
        runBlocking {
            // Lue périmée au lancement, mais cochée entre-temps : la transaction relit et la laisse ouverte.
            val list = newList()
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            lists.setNotFound(bread.id, now)
            visits.checkItem(visit.id, milk.id, CheckSubject.Category("dairy"), now + 50.minutes)

            assertFalse(visits.abandonVisit(visit.id, now + 60.minutes, staleAfter = 45.minutes))

            assertEquals(visit.id, visits.openVisit()?.id)
            assertEquals(now, db.items().get(bread.id)?.notFoundAt)
            assertFalse(OutboxKind.CloseVisit in kinds())
        }

    @Test
    fun abandoningAVisitWithoutChecksDeletesItAndAClosedOneIsLeftAlone() =
        runBlocking {
            val list = newList()
            val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val empty = visits.startVisit(store, list.id, false, now)
            lists.setNotFound(bread.id, now)
            assertTrue(visits.abandonVisit(empty.id, now + 1.minutes))
            assertNull(visits.visit(empty.id))
            assertNull(db.items().get(bread.id)?.notFoundAt)

            // Déjà close : la décision a été prise (« garder » ou « retirer »), rien ne change.
            val closed = visits.startVisit(store, list.id, false, now + 1.minutes)
            visits.checkItem(closed.id, milk.id, CheckSubject.Category("dairy"), now + 1.minutes)
            visits.closeVisit(closed.id, now + 2.minutes)
            lists.setNotFound(bread.id, now + 3.minutes)
            assertFalse(visits.abandonVisit(closed.id, now + 2.hours))
            assertEquals(now + 2.minutes, visits.visit(closed.id)?.endedAt)
            assertEquals(now + 3.minutes, db.items().get(bread.id)?.notFoundAt)
        }

    @Test
    fun abandoningAVisitThatNoLongerExistsDoesNothing() =
        runBlocking {
            // Supprimée faute de coche, ou renommée par une reprise de compte : le lancement ne doit pas planter.
            val list = newList()
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val gone = visits.startVisit(store, list.id, false, now)
            visits.closeVisit(gone.id, now)
            lists.setNotFound(bread.id, now)
            wakeUps = 0

            assertFalse(visits.abandonVisit(gone.id, now + 2.hours))
            assertFalse(visits.abandonVisit(id(), now + 2.hours, staleAfter = 45.minutes))

            assertEquals(now, db.items().get(bread.id)?.notFoundAt)
            assertEquals(0, wakeUps)
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
    fun anItemAlreadyCheckedRefusesASecondCheck() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
            try {
                visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now + 1.seconds)
                fail()
            } catch (expected: RepositoryException.AlreadyChecked) {
                assertEquals(item.id, expected.id)
            }
            assertEquals(1, visits.checks(visit.id).size)
            assertEquals(1, kinds().count { it == OutboxKind.InsertChecks })
        }

    @Test
    fun aClosedVisitRefusesChecks() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val bread = lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now)
            visits.closeVisit(visit.id, now + 1.minutes)
            try {
                visits.checkItem(visit.id, bread.id, CheckSubject.Category("bakery"), now)
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
    fun theClosureWaitsBehindAHeldCheck() =
        runBlocking {
            val list = newList()
            val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = visits.startVisit(store, list.id, false, now)
            visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now, sendAfter = 5.seconds)
            // Fin juste après la coche, pendant que « Annuler » est encore affiché.
            visits.closeVisit(visit.id, now + 1.seconds)
            advance(2.seconds)

            engine.drain()
            // Rien ne part : la clôture attend la coche, qui attend la fin de l'annulation.
            assertTrue(gateway.callsOf("closeVisit").isEmpty())
            assertTrue(gateway.callsOf("createVisit").isEmpty())

            advance(5.seconds)
            assertNull(engine.drain())
            val calls =
                gateway.calls.filter {
                    it.substringBefore(':') in
                        setOf("createVisit", "insertChecks", "closeVisit")
                }
            assertEquals(listOf("createVisit:${visit.id}", "insertChecks:1", "closeVisit:${visit.id}"), calls)
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

    // region Visite envoyée puis vidée (#62)

    private class Seed(
        val visit: VisitEntity,
        val item: ListItemEntity,
        val check: CheckEntity,
    )

    /**
     * Liste, article, visite commencée à `now`, une coche 30 s plus tard, puis une minute passe ; [sendAfter] retient
     * la coche (et la création).
     */
    private suspend fun seed(sendAfter: Duration = ZERO): Seed {
        val list = newList()
        val item = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
        val visit = visits.startVisit(store, list.id, false, now)
        val check = visits.checkItem(visit.id, item.id, CheckSubject.Category("dairy"), now + 30.seconds, sendAfter)
        advance(1.minutes)
        return Seed(visit, item, check)
    }

    /** `createVisit` part, `insertChecks` est retenu (`23503`), puis l'article est décoché : la coche disparaît. */
    private suspend fun sentThenUnchecked(): Seed {
        val seed = seed()
        gateway.failNext("insertChecks", RemoteError.DependencyMissing("23503"))
        engine.drain()
        assertEquals(listOf("createVisit:${seed.visit.id}"), gateway.callsOf("createVisit"))
        assertEquals(SyncState.SYNCED, db.visits().get(seed.visit.id)?.syncState)
        assertEquals(listOf(OutboxKind.InsertChecks), kinds())

        visits.uncheckItem(seed.item.id, seed.check.id, now + 1.minutes)
        assertTrue(visits.checks(seed.visit.id).isEmpty())
        assertEquals(listOf(OutboxKind.UpsertItem), kinds())
        return seed
    }

    /** La clôture part, à la date du début de visite, et aucune coche ne part. */
    private suspend fun assertClosureSent(visit: VisitEntity) {
        val closed = requireNotNull(db.visits().get(visit.id))
        assertEquals(visit.startedAt, closed.endedAt)
        assertEquals(SyncState.SYNCED, closed.syncState)
        assertEquals(SyncState.PENDING, closed.endSyncState)
        assertTrue(OutboxKind.CloseVisit in kinds())

        advance(1.hours)
        assertNull(engine.drain())
        assertTrue(db.outbox().all().isEmpty())
        assertEquals(listOf("closeVisit:${visit.id}"), gateway.callsOf("closeVisit"))
        assertTrue(gateway.savedChecks.isEmpty())
        assertEquals(SyncState.SYNCED, db.visits().get(visit.id)?.endSyncState)
    }

    @Test
    fun closingASentVisitWithoutChecksSendsItsClosure() =
        runBlocking {
            val seed = sentThenUnchecked()
            assertTrue(visits.closeVisit(seed.visit.id, now + 10.minutes))
            assertClosureSent(seed.visit)
        }

    @Test
    fun abandoningASentVisitWithoutChecksSendsItsClosure() =
        runBlocking {
            val seed = sentThenUnchecked()
            assertTrue(visits.abandonVisit(seed.visit.id, now + 3.hours, staleAfter = 45.minutes))
            assertClosureSent(seed.visit)
        }

    /** Une visite neuve abandonne l'ancienne de la même façon. */
    @Test
    fun startingAnotherVisitClosesTheSentOneWithoutChecks() =
        runBlocking {
            val seed = sentThenUnchecked()
            val other = visits.startVisit(store, seed.item.listId, false, now + 10.minutes, staleAfter = 1.minutes)
            assertFalse(other.id == seed.visit.id)
            assertClosureSent(seed.visit)
        }

    /** Création annulée pendant son envoi (coche retirée entre-temps) : le serveur l'a reçue, elle le sait. */
    @Test
    fun aCreationCancelledDuringItsSendStillCountsAsReceived() =
        runBlocking {
            val seed = seed()
            gateway.failNext("insertChecks", RemoteError.DependencyMissing("23503"))
            gateway.beforeCall = { method ->
                if (method == "createVisit") visits.uncheckItem(seed.item.id, seed.check.id, now + 1.minutes)
            }
            engine.drain()
            gateway.beforeCall = {}
            assertTrue(visits.checks(seed.visit.id).isEmpty())
            assertEquals(SyncState.SYNCED, db.visits().get(seed.visit.id)?.syncState)

            assertTrue(visits.closeVisit(seed.visit.id, now + 10.minutes))
            assertClosureSent(seed.visit)
        }

    /** Clôture perdue : la réconciliation la remet en file, même sans coche. */
    @Test
    fun reconciliationRequeuesTheClosureOfASentVisitWithoutChecks() =
        runBlocking {
            val seed = sentThenUnchecked()
            visits.closeVisit(seed.visit.id, now + 10.minutes)
            db
                .outbox()
                .pending()
                .filter { it.kind() == OutboxKind.CloseVisit }
                .forEach { db.outbox().delete(it.id) }
            assertFalse(OutboxKind.CloseVisit in kinds())

            OutboxReconciliation(db).run(now + 11.minutes)
            assertEquals(1, kinds().count { it == OutboxKind.CloseVisit })
            assertFalse(OutboxKind.CreateVisit in kinds())
        }

    /** Non-régression : jamais envoyée et sans coche, la visite est supprimée et rien ne part. */
    @Test
    fun aVisitNeverSentAndWithoutChecksIsStillDeleted() =
        runBlocking {
            for (abandoning in listOf(false, true)) {
                val seed = seed(sendAfter = 5.seconds)
                visits.uncheckItem(seed.item.id, seed.check.id, now)
                assertFalse(OutboxKind.CreateVisit in kinds())
                if (abandoning) {
                    assertTrue(visits.abandonVisit(seed.visit.id, now + 3.hours))
                } else {
                    assertFalse(visits.closeVisit(seed.visit.id, now + 10.minutes))
                }
                assertNull(visits.visit(seed.visit.id))
                assertFalse(OutboxKind.CloseVisit in kinds())
            }

            advance(1.hours)
            assertNull(engine.drain())
            assertTrue(gateway.callsOf("createVisit").isEmpty())
            assertTrue(gateway.callsOf("closeVisit").isEmpty())
        }

    // endregion
}
