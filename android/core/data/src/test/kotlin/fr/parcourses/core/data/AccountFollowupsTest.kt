package fr.parcourses.core.data

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountSession
import fr.parcourses.core.data.account.AccountSwitchReplay
import fr.parcourses.core.data.account.ContinueWithoutAccount
import fr.parcourses.core.data.account.DeletionGuardedGateway
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.account.InMemoryAccountSwitchFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.SyncDependencies
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListRow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.days
import kotlin.uuid.Uuid

/** Suites de la relecture de #94 (#87, lot 87.5) : changement de compte interrompu et cas voisins. */
@RunWith(AndroidJUnit4::class)
class AccountFollowupsTest : DataTest() {
    private val gateway = fakeGateway()
    private val kind = InMemoryAccountKindFlag()
    private val switch = InMemoryAccountSwitchFlag()
    private val cursors = InMemorySyncCursors()
    private val lock = Mutex()
    private var purges = 0
    private val guarded by lazy { DeletionGuardedGateway(gateway, InMemoryAccountDeletionFlag(), kind) }
    private val deps =
        SyncDependencies(
            now = { now },
            jitter = { 1.0 },
            isOnline = { online },
            isAccountDeletionPending = { switch.isPending },
            accountKind = { kind.kind.value },
        )
    private val engine by lazy { SyncEngine(guarded, db, cursors, classify, deps) }
    private val repository by lazy { RoomListRepository(db) }

    private val replay by lazy {
        AccountSwitchReplay(guarded, switch, cursors, kind, lock) {
            purges++
            LocalDataPurge(db, cursors, accountKind = kind).run()
        }
    }

    /**
     * Bloquant : un compte e-mail se connecte toujours sans session. Processus arrêté pendant `verifyCode` : au
     * lancement, aucune session = aucun compte à protéger, le drapeau part et « Se reconnecter » revient.
     */
    @Test
    fun anInterruptedSwitchWithoutSessionClearsTheFlagAndAsksToReconnect() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository.createList("Courses", now)
            switch.write()
            gateway.hasSession = false

            assertTrue(replay.run())

            assertFalse(switch.isPending)
            assertEquals(0, purges)
            assertEquals(1, db.lists().getAll().size)
            engine.drain(pull = true)
            engine.drain(pull = true)
            val state = AccountSession(guarded, kind, engine.waitsForSession).state.first()
            assertTrue(state.needsSignIn)
            assertTrue(gateway.callsOf("ensureSession").isEmpty())
        }

    @Test
    fun anInterruptedSwitchToAnotherEmailAccountReplaysThePurgeAndAdoptsIt() =
        runBlocking {
            kind.write(AccountKind.Email)
            repository.createList("Courses de A", now)
            cursors.accountId = Uuid.random()
            switch.write()
            gateway.email = "tom@exemple.fr"

            assertTrue(replay.run())

            assertEquals(1, purges)
            assertTrue(db.lists().getAll().isEmpty())
            assertEquals(gateway.account, cursors.accountId)
            assertEquals(AccountKind.Email, cursors.accountKind)
            assertEquals(AccountKind.Email, kind.kind.value)
            assertEquals(listOf(gateway.account), gateway.acknowledged)
            assertFalse(switch.isPending)
        }

    @Test
    fun theSameAccountOrAnAnonymousSessionOnlyClearsTheFlag() =
        runBlocking {
            switch.write()
            gateway.email = null
            cursors.accountId = Uuid.random()
            assertTrue(replay.run())
            assertEquals(0, purges)
            assertFalse(switch.isPending)

            switch.write()
            gateway.email = "lea@exemple.fr"
            cursors.accountId = gateway.account
            assertTrue(replay.run())
            assertEquals(0, purges)
            assertFalse(switch.isPending)
        }

    /** Mineur 2 : la reprise attend le verrou de compte (vérification de code en cours). */
    @Test
    fun theReplayWaitsForTheAccountLock() =
        runBlocking {
            switch.write()
            gateway.hasSession = false
            lock.lock()
            val job = launch { replay.run() }
            yield()
            assertTrue(switch.isPending)
            lock.unlock()
            job.join()
            assertFalse(switch.isPending)
        }

    /** Mineur 4 : une panne de la purge reprend la synchronisation au lieu de planter. */
    @Test
    fun continuingWithoutAccountResumesTheSyncOnAnyFailure() =
        runBlocking {
            kind.write(AccountKind.Email)
            val steps = mutableListOf<String>()
            var failing = true
            val host =
                object : AccountDeletionHost {
                    override suspend fun suspendSync() {
                        steps += "suspend"
                    }

                    override suspend fun endShopping() = Unit

                    override suspend fun clearLocalState() {
                        if (failing) error("SQLite verrouillé")
                    }

                    override fun resumeSync() {
                        steps += "resume"
                    }

                    override suspend fun rebuild() {
                        steps += "rebuild"
                    }
                }
            val reset = ContinueWithoutAccount(guarded, LocalDataPurge(db, cursors, accountKind = kind), host)
            assertFalse(reset.run())
            assertEquals(listOf("suspend", "resume"), steps)

            failing = false
            steps.clear()
            gateway.hasSession = false
            val before = gateway.account
            assertTrue(reset.run())
            assertEquals(listOf("suspend", "rebuild"), steps)
            assertEquals(AccountKind.Anonymous, kind.kind.value)
            assertNotEquals(before, gateway.account)
        }

    /** Mineur 6 : sans heure du serveur, une réconciliation complète par passe au plus, descente comprise. */
    @Test
    fun atMostOneFullReconciliationPerPass() =
        runBlocking {
            val listId = Uuid.random()
            val itemId = Uuid.random()
            gateway.remoteLists = listOf(ListRow(listId, gateway.account, "L", now, now))
            gateway.remoteItems =
                listOf(ListItemRow(itemId, listId, null, "lait", null, null, now, now, gateway.account))
            gateway.serverDate = now
            engine.drain(pull = true)
            gateway.serverDate = null
            cursors.tombstones = now - 30.days
            repository.setChecked(itemId.toString(), now, now)
            gateway.calls.clear()

            engine.drain(pull = true)

            assertEquals(1, gateway.callsOf("fetchItemIds").size)
        }
}
