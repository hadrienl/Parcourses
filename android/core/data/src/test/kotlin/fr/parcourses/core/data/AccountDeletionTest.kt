package fr.parcourses.core.data

import android.content.Context
import androidx.room3.useReaderConnection
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionError
import fr.parcourses.core.data.account.AccountDeletionFlag
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountDeletionMarker
import fr.parcourses.core.data.account.AccountDeletionOutcome
import fr.parcourses.core.data.account.AccountDeletionPhase
import fr.parcourses.core.data.account.AccountDeletionTiming
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.repository.RoomVisitRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.ListSyncWorker
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.data.sync.SyncScheduler
import fr.parcourses.core.data.sync.SyncWorkerFactory
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.entity.GraphSnapshotEntity
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * « Supprimer mes données » (#68 §5.3, §8.2) : purge complète, aucune reprise de compte vers le nouveau compte,
 * reprise après la mort du processus à chaque étape, réponse perdue, hors ligne, refus.
 */
@RunWith(AndroidJUnit4::class)
@Suppress("LargeClass")
class AccountDeletionTest : DataTest() {
    /** Mort du processus simulée : ce n'est pas une `Exception`, rien ne la rattrape en chemin. */
    private class Killed : Error("processus tué")

    private val gateway = FakeRemoteGateway()
    private val flag = KillableFlag(InMemoryAccountDeletionFlag())
    private val cursors = InMemorySyncCursors()
    private val guarded = DeletionGuardedGateway(gateway, flag)
    private val syncDependencies =
        SyncDependencies(
            now = { now },
            jitter = { 1.0 },
            isOnline = { online },
            isAccountDeletionPending = { flag.isPending },
        )
    private lateinit var engine: SyncEngine
    private val host = Host()
    private val storeId = "00000000-0000-4000-8000-000000000001"

    /** `ensureSession` atteint le serveur alors que le drapeau existe : ne doit jamais arriver. */
    private var sessionsWhilePending = 0

    init {
        gateway.beforeCall = { method -> if (method == "ensureSession" && flag.isPending) sessionsWhilePending++ }
    }

    private fun newEngine() = SyncEngine(guarded, db, cursors, classify, syncDependencies)

    // Après l'ouverture de la base (`DataTest`, dont le `@Before` passe d'abord).
    @Before
    fun createEngine() {
        engine = newEngine()
    }

    /** Un lancement de l'app : moteur neuf, rien en mémoire ; base, drapeau, session et serveur restent. */
    private fun deletion(withServer: Boolean = true) =
        AccountDeletion(
            gateway = if (withServer) guarded else null,
            flag = flag,
            purge = LocalDataPurge(db, cursors),
            host = host,
            isOnline = { online },
            timing = AccountDeletionTiming(timeout = 200.milliseconds, now = { now }),
        )

    private inner class Host : AccountDeletionHost {
        val events = mutableListOf<String>()
        var killAt: String? = null
        var failClear = false

        private fun step(name: String) {
            events += name
            if (killAt == name) {
                killAt = null
                throw Killed()
            }
        }

        override suspend fun suspendSync() {
            engine.suspend()
            step("suspendSync")
        }

        override suspend fun endShopping() = step("endShopping")

        override suspend fun clearLocalState() {
            step("clearLocalState")
            check(!failClear) { "préférences non effacées" }
        }

        override fun resumeSync() {
            events += "resumeSync"
            engine.resume()
        }

        override suspend fun rebuild() {
            step("rebuild")
            engine = newEngine()
        }
    }

    /** Drapeau dont l'effacement peut « tuer le processus » juste avant d'avoir lieu. */
    private class KillableFlag(
        private val inner: AccountDeletionFlag,
    ) : AccountDeletionFlag by inner {
        var killOnClear = false

        override fun clear() {
            if (killOnClear) {
                killOnClear = false
                throw Killed()
            }
            inner.clear()
        }
    }

    // region Outils

    private val lists by lazy { RoomListRepository(db) }
    private val visits by lazy { RoomVisitRepository(db) }

    /**
     * Ce qu'un compte laisse sur l'appareil : une liste envoyée à l'ancien compte, un article encore en file, une
     * visite ouverte avec sa coche (en file), un magasin récent, un instantané, le catalogue. Renvoie l'ancien compte.
     */
    private suspend fun everythingOnTheDevice(): Uuid {
        val list = lists.createList("Courses", now)
        val milk = lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
        lists.addItem(list.id, "pain", "pain", null, null, "bakery", now)
        assertNull(engine.drain())
        assertEquals(gateway.account, cursors.accountId)
        val visit = visits.startVisit(storeId, list.id, false, now)
        visits.checkItem(visit.id, milk.id, CheckSubject.Category("dairy"), now)
        lists.addItem(list.id, "pommes", "pomme", null, null, "produce", now)
        db.stores().upsert(StoreEntity(storeId, "Carrefour", lastUsedAt = now))
        db.graphSnapshots().upsert(GraphSnapshotEntity(storeId, 1, 1, 0, now, "{}".encodeToByteArray()))
        db.products().upsertAll(listOf(ProductEntity("p-1", "Lait", "lait", "dairy")))
        cursors.catalog = now
        assertTrue(db.outbox().all().isNotEmpty())
        return gateway.account
    }

    private suspend fun count(table: String): Long =
        db.useReaderConnection { connection ->
            connection.usePrepared("SELECT count(*) FROM $table") {
                it.step()
                it.getLong(0)
            }
        }

    private val personalTables =
        listOf("lists", "list_items", "visits", "checks", "outbox", "stores", "graph_snapshots", "products")

    /** État final attendu, quel que soit le chemin : appareil vide, ancien compte supprimé, aucun renvoi. */
    private suspend fun assertDeletedAndStartedAfresh(old: Uuid) {
        assertNull(flag.read())
        for (table in personalTables) assertEquals(table, 0L, count(table))
        assertEquals(
            CategorySeed
                .bundled()
                .categories.size
                .toLong(),
            count("categories"),
        )
        assertEquals(1L, count("category_seed_state"))
        assertNull(cursors.lists)
        assertNull(cursors.items)
        assertNull(cursors.catalog)
        assertEquals(listOf(old), gateway.deletedAccounts)
        assertEquals(0, sessionsWhilePending)
        assertTrue(gateway.callsOf("closeVisit").isEmpty())

        // Synchronisation sur le nouveau compte : rien ne repart, aucune reprise de compte.
        val mark = gateway.calls.size
        engine.drain(pull = true)
        val after = gateway.calls.drop(mark).map { it.substringBefore(':') }
        assertNotEquals(old, gateway.account)
        assertEquals(gateway.account, cursors.accountId)
        val uploads =
            setOf("saveList", "saveItem", "deleteList", "deleteItem", "createVisit", "insertChecks", "closeVisit")
        assertTrue("$after", after.none { it in uploads })
        assertTrue(gateway.acknowledged.isEmpty())
        assertTrue(db.outbox().all().isEmpty())
    }

    private fun expectKilled(block: suspend () -> Unit) =
        runBlocking {
            try {
                block()
                fail("le processus aurait dû mourir")
            } catch (_: Killed) {
            }
        }

    // endregion

    // region Déroulé normal

    @Test
    fun aDeletionPurgesEverythingAndTheNewAccountReceivesNothing() =
        runBlocking {
            val old = everythingOnTheDevice()

            assertEquals(AccountDeletionOutcome.Deleted, deletion().run())

            assertEquals(listOf("suspendSync", "endShopping", "clearLocalState", "rebuild"), host.events)
            val order = gateway.calls.map { it.substringBefore(':') }
            assertTrue(order.indexOf("deleteAccount") < order.indexOf("signOutLocally"))
            assertTrue(order.indexOf("signOutLocally") < order.lastIndexOf("ensureSession"))
            assertDeletedAndStartedAfresh(old)
        }

    @Test
    fun withoutThePurgeTheNewAccountWouldReceiveEverything() =
        runBlocking {
            // Témoin du risque (#68 §2) : un nouveau compte sans purge déclenche la reprise de compte et le renvoi.
            everythingOnTheDevice()
            gateway.account = Uuid.random()

            engine.drain(pull = true)

            assertEquals(listOf(gateway.account), gateway.acknowledged)
            assertTrue(gateway.callsOf("saveList").size >= 2)
        }

    @Test
    fun whileTheFlagExistsNoAccountIsCreatedAndNothingIsSynchronised() =
        runBlocking {
            everythingOnTheDevice()
            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, gateway.account.toString()))
            gateway.hasSession = false
            val mark = gateway.calls.size

            try {
                guarded.ensureSession()
                fail("ensureSession aurait dû refuser")
            } catch (_: RemoteError.Unauthorized) {
            }
            assertNull(engine.drain(pull = true))
            assertFalse(engine.hasPendingRun)

            assertEquals(emptyList<String>(), gateway.calls.drop(mark))
            assertTrue(gateway.callsOf("ensureSession").none())
        }

    @Test
    fun theWorkerDoesNothingAndSchedulesNoWakeWhileTheFlagExists() =
        runBlocking {
            everythingOnTheDevice()
            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))
            val scheduler = RecordingScheduler()
            val mark = gateway.calls.size
            val worker: ListenableWorker =
                TestListenableWorkerBuilder<ListSyncWorker>(ApplicationProvider.getApplicationContext<Context>())
                    .setWorkerFactory(SyncWorkerFactory({ engine }, scheduler))
                    .build()

            assertEquals(ListenableWorker.Result.success(), worker.startWork().get())

            assertEquals(emptyList<String>(), gateway.calls.drop(mark))
            assertTrue(scheduler.wakes.isEmpty())
        }

    @Test
    fun suspendingWaitsForThePassInProgress() =
        runBlocking {
            lists.createList("Courses", now)
            val release = CompletableDeferred<Unit>()
            val sending = CompletableDeferred<Unit>()
            gateway.beforeCall = { method ->
                if (method == "saveList") {
                    sending.complete(Unit)
                    release.await()
                }
            }
            val pass = launch { engine.drain() }
            sending.await()
            val suspended = async { engine.suspend() }
            yield()
            assertFalse(suspended.isCompleted)

            release.complete(Unit)
            suspended.await()
            pass.join()

            // Arrêté : une demande reste notée, sans passe.
            lists.createList("Autre", now)
            val mark = gateway.calls.size
            assertNull(engine.drain())
            assertEquals(mark, gateway.calls.size)
            engine.resume()
            engine.drain()
            assertTrue(gateway.calls.drop(mark).any { it.startsWith("saveList") })
        }

    @Test
    fun aBuildWithoutServerOnlyPurgesTheDevice() =
        runBlocking {
            everythingOnTheDevice()
            val mark = gateway.calls.size

            assertEquals(AccountDeletionOutcome.Deleted, deletion(withServer = false).run())

            assertEquals(mark, gateway.calls.size)
            assertNull(flag.read())
            for (table in personalTables) assertEquals(table, 0L, count(table))
            assertEquals(1L, count("category_seed_state"))
        }

    // endregion

    // region Erreurs

    @Test
    fun offlineNothingIsTouched() =
        runBlocking {
            everythingOnTheDevice()
            val outbox = db.outbox().all().size
            online = false
            val mark = gateway.calls.size

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Offline), deletion().run())

            assertNull(flag.read())
            assertTrue(host.events.isEmpty())
            assertEquals(mark, gateway.calls.size)
            assertEquals(1L, count("lists"))
            assertEquals(outbox, db.outbox().all().size)
        }

    @Test
    fun aRefusalErasesNothingAndResumesTheSync() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Rejected("PGRST202"))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Refused), deletion().run())

            assertNull(flag.read())
            assertTrue(gateway.deletedAccounts.isEmpty())
            assertEquals("resumeSync", host.events.last())
            assertEquals(1L, count("lists"))
            assertEquals(1L, count("visits"))
            // La synchronisation reprend : l'article en file part.
            engine.drain()
            assertTrue(gateway.callsOf("saveItem").size >= 3)
        }

    @Test
    fun aLostResponseIsSettledByTheServerAnsweringNotFound() =
        runBlocking {
            val old = everythingOnTheDevice()
            gateway.lostDeleteResponse = RemoteError.Network()

            assertEquals(AccountDeletionOutcome.Deleted, deletion().run())

            assertEquals(1, gateway.callsOf("verifySession").size)
            assertDeletedAndStartedAfresh(old)
        }

    @Test
    fun aTemporaryErrorOnAnExistingAccountOffersToRetry() =
        runBlocking {
            val old = everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Server("55P03"))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            // Le drapeau reste, rien n'est effacé, rien ne se synchronise.
            assertEquals(AccountDeletionPhase.Requested, flag.read()?.phase)
            assertEquals(1L, count("lists"))
            val mark = gateway.calls.size
            assertNull(engine.drain(pull = true))
            assertEquals(mark, gateway.calls.size)

            // « Réessayer ».
            assertEquals(AccountDeletionOutcome.Deleted, deletion().run())
            assertDeletedAndStartedAfresh(old)
        }

    @Test
    fun aTimeoutIsADoubtNotARefusal() =
        runBlocking {
            everythingOnTheDevice()
            gateway.beforeCall = { method -> if (method == "deleteAccount") delay(1_000) }

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            assertEquals(AccountDeletionPhase.Requested, flag.read()?.phase)
            assertEquals(1, gateway.callsOf("verifySession").size)
        }

    @Test
    fun cancellingAnUnconfirmedDeletionOfAnExistingAccountResumesTheSync() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Network())
            deletion().run()
            advance(31.seconds)

            assertEquals(AccountDeletionOutcome.Cancelled, deletion().cancel())

            assertNull(flag.read())
            assertEquals("resumeSync", host.events.last())
            assertEquals(1L, count("lists"))
            engine.drain()
            assertTrue(gateway.callsOf("saveItem").size >= 3)
        }

    @Test
    fun cancellingCannotHappenWhileTheServerCannotBeReached() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Network())
            gateway.failNext("verifySession", RemoteError.Network(), times = 2)
            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())
            advance(31.seconds)

            // On ne sait pas si le serveur a supprimé : rendre la synchronisation pourrait tout renvoyer.
            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().cancel())

            assertEquals(AccountDeletionPhase.Requested, flag.read()?.phase)
        }

    @Test
    fun cancellingAfterTheServerDeletedTheAccountFinishesThePurge() =
        runBlocking {
            val old = everythingOnTheDevice()
            gateway.lostDeleteResponse = RemoteError.Network()
            gateway.failNext("verifySession", RemoteError.Network())
            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())
            advance(31.seconds)

            assertEquals(AccountDeletionOutcome.Deleted, deletion().cancel())

            assertDeletedAndStartedAfresh(old)
        }

    /** Reprise d'une suppression déjà tentée : le drapeau dit qu'une RPC est peut-être passée. */
    private fun attempted(account: Uuid) =
        AccountDeletionMarker(AccountDeletionPhase.Requested, account.toString(), now - 1.minutes)

    @Test
    fun afterAnAttemptALockedStorageIsADoubtNotARefusal() =
        runBlocking {
            val account = everythingOnTheDevice()
            flag.write(attempted(account))
            gateway.failNext("deleteAccount", RemoteError.SecureStorageLocked())

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().resumePending())

            assertTrue(flag.isPending)
            assertEquals(1L, count("lists"))
        }

    @Test
    fun aLockedStorageIsADoubtEvenAtTheFirstAttempt() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.SecureStorageLocked())
            gateway.failNext("sessionAccountId", RemoteError.SecureStorageLocked(), times = 3)

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            assertTrue(flag.isPending)
        }

    @Test
    fun afterAnAttemptARefusalIsOnlyBelievedOnceTheAccountIsFound() =
        runBlocking {
            val account = everythingOnTheDevice()
            // 400 de l'Auth sans code : un refus, mais la tentative d'avant a peut-être supprimé le compte.
            flag.write(attempted(account))
            gateway.failNext("deleteAccount", RemoteError.Server("400"))
            gateway.failNext("verifySession", RemoteError.Network())

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().resumePending())
            assertTrue(flag.isPending)

            // Compte trouvé : le refus est cru, rien n'est effacé.
            gateway.failNext("deleteAccount", RemoteError.Server("400"))
            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Refused), deletion().run())
            assertNull(flag.read())
            assertEquals(1L, count("lists"))
            assertEquals(2, gateway.callsOf("verifySession").size)
        }

    @Test
    fun atTheFirstAttemptARefusalNeedsNoVerification() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Server("400"))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Refused), deletion().run())

            assertTrue(gateway.callsOf("verifySession").isEmpty())
            assertNull(flag.read())
        }

    /** C4 : une requête jamais partie est un « hors ligne » : rien n'est touché, tout reprend. */
    @Test
    fun aRequestThatNeverLeftIsOfflineAndNothingIsErased() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Network(notSent = true))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Offline), deletion().run())

            assertNull(flag.read())
            assertEquals("resumeSync", host.events.last())
            assertEquals(1L, count("lists"))
        }

    @Test
    fun aConnectionCutDuringTheRequestIsADoubt() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Network(notSent = false))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            assertTrue(flag.isPending)
        }

    @Test
    fun afterAnAttemptARequestThatNeverLeftStillNeedsTheAccountToBeFound() =
        runBlocking {
            val account = everythingOnTheDevice()
            flag.write(attempted(account))
            gateway.failNext("deleteAccount", RemoteError.Network(notSent = true))
            gateway.failNext("verifySession", RemoteError.Network(notSent = true))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().resumePending())
            assertTrue(flag.isPending)
        }

    /** C1 : seul un code GoTrue de suppression vaut preuve ; `bad_jwt` reste un doute. */
    @Test
    fun onlyTheDeletionCodesProveTheDeletion() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Server("502"))
            gateway.failNext("verifySession", RemoteError.Unauthorized(authCode = "bad_jwt"))

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            assertTrue(flag.isPending)
            assertEquals(1L, count("lists"))
        }

    /** C2 : « Annuler » juste après une tentative : la RPC peut encore aboutir, « Réessayez dans un instant. ». */
    @Test
    fun cancellingTooSoonAfterAnAttemptChangesNothing() =
        runBlocking {
            everythingOnTheDevice()
            gateway.failNext("deleteAccount", RemoteError.Server("503"))
            deletion().run()
            advance(10.seconds)

            assertEquals(
                AccountDeletionOutcome.Failed(AccountDeletionError.Unknown, retrySoon = true),
                deletion().cancel(),
            )

            assertTrue(flag.isPending)
            assertEquals(1, gateway.callsOf("verifySession").size)
        }

    @Test
    fun cancellingWithoutLocalSessionKeepsTheData() =
        runBlocking {
            val account = everythingOnTheDevice()
            flag.write(attempted(account))
            gateway.hasSession = false

            assertEquals(AccountDeletionOutcome.Cancelled, deletion().cancel())

            assertNull(flag.read())
            assertEquals(1L, count("lists"))
            assertEquals("resumeSync", host.events.last())
        }

    @Test
    fun aBuildWithoutServerCancelsWithoutPurging() =
        runBlocking {
            everythingOnTheDevice()
            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))

            assertEquals(AccountDeletionOutcome.Cancelled, deletion(withServer = false).cancel())

            assertNull(flag.read())
            assertEquals(1L, count("lists"))
        }

    @Test
    fun aFailureToClearTheLiveUpdatePreferencesKeepsTheFlag() =
        runBlocking {
            everythingOnTheDevice()
            host.killAt = null
            host.failClear = true

            assertEquals(AccountDeletionOutcome.Failed(AccountDeletionError.Unknown), deletion().run())

            assertEquals(AccountDeletionPhase.ServerDeleted, flag.read()?.phase)
            host.failClear = false
            assertEquals(AccountDeletionOutcome.Deleted, deletion().run())
            assertNull(flag.read())
        }

    // endregion

    // region Reprise après la mort du processus

    /** Tue le processus pendant une étape, relance l'app, et vérifie que l'état final est le même. */
    private fun killedThenRelaunched(kill: () -> Unit) =
        runBlocking {
            val old = everythingOnTheDevice()
            kill()
            expectKilled { deletion().run() }

            // Relance : moteur neuf, le drapeau dit si la suppression doit reprendre.
            engine = newEngine()
            val pending = flag.isPending
            if (pending) {
                // Tant que le drapeau existe, le moteur neuf ne fait rien.
                val mark = gateway.calls.size
                assertNull(engine.drain(pull = true))
                assertEquals(mark, gateway.calls.size)
            }
            val outcome = deletion().resumePending()
            if (pending) {
                assertEquals(AccountDeletionOutcome.Deleted, outcome)
            } else {
                assertNull(outcome)
                // Lancement ordinaire : connexion anonyme.
                guarded.ensureSession()
            }
            assertDeletedAndStartedAfresh(old)
        }

    @Test
    fun killedRightAfterTheFlag() = killedThenRelaunched { host.killAt = "suspendSync" }

    @Test
    fun killedAfterTheLiveUpdateWasEnded() = killedThenRelaunched { host.killAt = "endShopping" }

    @Test
    fun killedOnceTheServerHadDeleted() = killedThenRelaunched { gateway.lostDeleteResponse = Killed() }

    @Test
    fun killedAfterThePurgeBeforeSigningOut() = killedThenRelaunched { gateway.failNext("signOutLocally", Killed()) }

    @Test
    fun killedJustBeforeTheFlagWasErased() = killedThenRelaunched { flag.killOnClear = true }

    @Test
    fun killedBeforeTheNewAccount() = killedThenRelaunched { gateway.failNext("ensureSession", Killed()) }

    @Test
    fun killedWhileTheAppWasRebuilt() = killedThenRelaunched { host.killAt = "rebuild" }

    /** C3 : relance avec le drapeau et sans session locale : l'appareil est purgé, avec un message distinct. */
    @Test
    fun aRelaunchWithoutSessionPurgesTheDeviceAndSaysSo() =
        runBlocking {
            val old = everythingOnTheDevice()
            // Le serveur a supprimé, puis la session a disparu de l'appareil avant la fin (processus tué).
            gateway.deletedAccounts += old
            gateway.hasSession = false
            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, old.toString()))

            assertEquals(AccountDeletionOutcome.DeletedLocally, deletion().resumePending())

            assertTrue(gateway.callsOf("deleteAccount").isEmpty())
            assertDeletedAndStartedAfresh(old)
        }

    /** C7 : la session locale est celle d'un autre compte que le drapeau : traitée comme une session absente. */
    @Test
    fun aSessionOfAnotherAccountIsNeverDeletedInsteadOfTheFlaggedOne() =
        runBlocking {
            everythingOnTheDevice()
            val other = gateway.account
            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, Uuid.random().toString()))

            assertEquals(AccountDeletionOutcome.DeletedLocally, deletion().resumePending())

            assertTrue(gateway.callsOf("deleteAccount").isEmpty())
            assertTrue(gateway.deletedAccounts.isEmpty())
            assertNull(flag.read())
            for (table in personalTables) assertEquals(table, 0L, count(table))
            assertNotEquals(other, gateway.account)
        }

    @Test
    fun theFlagIsWrittenBeforeTheSessionIsReadAndThenNamesItsAccount() =
        runBlocking {
            everythingOnTheDevice()
            val account = gateway.account
            var pendingWhileReading: Boolean? = null
            gateway.beforeCall = { method -> if (method == "sessionAccountId") pendingWhileReading = flag.isPending }
            gateway.failNext("deleteAccount", RemoteError.Server("503"))

            deletion().run()

            assertEquals(true, pendingWhileReading)
            assertEquals(account.toString(), flag.read()?.accountId)
            assertEquals(now, flag.read()?.lastAttemptAt)
        }

    @Test
    fun nothingToResumeWithoutTheFlag() =
        runBlocking {
            everythingOnTheDevice()
            assertNull(deletion().resumePending())
            assertEquals(1L, count("lists"))
        }

    // endregion

    private class RecordingScheduler : SyncScheduler {
        val wakes = mutableListOf<Instant>()

        override fun enqueue(pull: Boolean) = Unit

        override fun scheduleWake(at: Instant) {
            wakes += at
        }

        override fun schedulePeriodic() = Unit

        override suspend fun cancelAll() = Unit
    }
}
