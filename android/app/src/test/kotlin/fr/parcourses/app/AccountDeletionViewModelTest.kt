package fr.parcourses.app

import android.app.Application
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionError
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountDeletionMarker
import fr.parcourses.core.data.account.AccountDeletionPhase
import fr.parcourses.core.data.account.InMemoryAccountDeletionFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Confirmation et états de « Supprimer mes données » (#68) : rien sans confirmation, une seule suppression. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountDeletionViewModelTest {
    @Before
    fun setUp() = Dispatchers.setMain(Dispatchers.Unconfined)

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        scope.cancel()
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val deletion = MutableStateFlow<AccountDeletionState>(AccountDeletionState.Idle)
    private var starts = 0
    private var visitOpen = false

    private fun model(localOnly: Boolean = false) =
        AccountDeletionViewModel(
            deletion = deletion,
            hasOpenVisit = { visitOpen },
            start = {
                starts++
                deletion.value = AccountDeletionState.Running
                true
            },
            localOnly = localOnly,
        )

    @Test
    fun nothingStartsWithoutConfirmation() {
        val model = model()
        model.actions.onRequest()
        assertTrue(model.state.value.confirming)
        model.actions.onDismiss()
        assertFalse(model.state.value.confirming)
        assertEquals(0, starts)
    }

    @Test
    fun aDoubleTapStartsASingleDeletion() {
        val model = model()
        model.actions.onRequest()
        model.actions.onRequest()
        model.actions.onConfirm()
        model.actions.onConfirm()
        assertEquals(1, starts)
        assertTrue(model.state.value.running)
        assertFalse(model.state.value.confirming)
        // Pendant la suppression, le bouton ne rouvre pas la confirmation.
        model.actions.onRequest()
        assertFalse(model.state.value.confirming)
    }

    @Test
    fun theConfirmationWarnsWhenAVisitIsOpen() {
        visitOpen = true
        val model = model()
        model.actions.onRequest()
        assertTrue(model.state.value.visitOpen)
    }

    @Test
    fun anUnreadableVisitStillOpensTheConfirmation() {
        val model =
            AccountDeletionViewModel(
                deletion = deletion,
                hasOpenVisit = { error("base illisible") },
                start = { true },
                localOnly = false,
            )
        model.actions.onRequest()
        assertTrue(model.state.value.confirming)
        assertFalse(model.state.value.visitOpen)
    }

    @Test
    fun aBuildWithoutServerSaysSo() {
        assertTrue(model(localOnly = true).state.value.localOnly)
        assertFalse(model().state.value.localOnly)
    }

    // region Contrôleur

    private val db =
        ParcoursesDatabaseFactory.createInMemory(
            RuntimeEnvironment.getApplication(),
            Dispatchers.IO,
            AndroidSQLiteDriver(),
        )

    @After
    fun closeDatabase() = db.close()

    private class Host : AccountDeletionHost {
        var gate: CompletableDeferred<Unit>? = null
        var rebuilds = 0

        override suspend fun suspendSync() {
            gate?.await()
        }

        override suspend fun endShopping() = Unit

        override suspend fun clearLocalState() = Unit

        override fun resumeSync() = Unit

        override suspend fun rebuild() {
            rebuilds++
        }
    }

    private fun controller(
        host: Host,
        flag: InMemoryAccountDeletionFlag = InMemoryAccountDeletionFlag(),
    ) = AccountDeletionController(
        AccountDeletion(null, flag, LocalDataPurge(db, InMemorySyncCursors()), host, isOnline = { true }),
        scope,
    )

    @Test
    fun theControllerRunsOneDeletionAtATimeThenReportsIt() =
        runBlocking {
            val host = Host().apply { gate = CompletableDeferred() }
            val controller = controller(host)

            assertTrue(controller.start())
            assertEquals(AccountDeletionState.Running, controller.state.value)
            assertFalse(controller.start())
            // Le voile reste : le message ne se ferme pas pendant la suppression.
            controller.acknowledge()
            assertEquals(AccountDeletionState.Running, controller.state.value)

            host.gate?.complete(Unit)
            withTimeout(5_000) { controller.state.first { it == AccountDeletionState.Done } }
            assertEquals(1, host.rebuilds)
            controller.acknowledge()
            assertEquals(AccountDeletionState.Idle, controller.state.value)
        }

    @Test
    fun aDeletionInterruptedByTheProcessResumesAtLaunch() =
        runBlocking {
            val flag = InMemoryAccountDeletionFlag()
            val host = Host()
            assertFalse(controller(host, flag).resumeAtLaunch())

            flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))
            host.gate = CompletableDeferred()
            val controller = controller(host, flag)
            assertTrue(controller.resumeAtLaunch())
            // Suppression déjà en cours : le lancement ne doit toujours rien démarrer d'autre.
            assertTrue(controller.resumeAtLaunch())
            host.gate?.complete(Unit)
            withTimeout(5_000) { controller.state.first { it == AccountDeletionState.Done } }
            assertFalse(flag.isPending)
        }

    @Test
    fun offlineTheMessageStaysUntilDismissedAndNothingIsTouched() =
        runBlocking {
            val flag = InMemoryAccountDeletionFlag()
            // Aucune méthode de la passerelle ne doit être appelée : hors ligne, rien ne part.
            val gateway =
                java.lang.reflect.Proxy.newProxyInstance(
                    RemoteGateway::class.java.classLoader,
                    arrayOf(RemoteGateway::class.java),
                ) { _, method, _ -> throw UnsupportedOperationException(method.name) } as RemoteGateway
            val controller =
                AccountDeletionController(
                    AccountDeletion(
                        gateway,
                        flag,
                        LocalDataPurge(db, InMemorySyncCursors()),
                        Host(),
                        isOnline = { false },
                    ),
                    scope,
                )

            controller.start()
            val failed = AccountDeletionState.Failed(AccountDeletionError.Offline)
            withTimeout(5_000) { controller.state.first { it == failed } }
            assertFalse(flag.isPending)

            controller.acknowledge()
            assertEquals(AccountDeletionState.Idle, controller.state.value)
        }

    // endregion
}
