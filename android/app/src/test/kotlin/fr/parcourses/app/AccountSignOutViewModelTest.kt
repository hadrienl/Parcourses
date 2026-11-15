package fr.parcourses.app

import android.app.Application
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionHost
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.InMemoryAccountSignOutFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.lang.reflect.Proxy

/** « Se déconnecter » (#87, suites de la relecture) : la synchro arrêtée pour compter reprend toujours. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountSignOutViewModelTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
    private val steps = mutableListOf<String>()
    private val db =
        ParcoursesDatabaseFactory.createInMemory(
            ApplicationProvider.getApplicationContext(),
            Dispatchers.IO,
            AndroidSQLiteDriver(),
        )

    private val host =
        object : AccountDeletionHost {
            override suspend fun suspendSync() {
                steps += "suspend"
            }

            override suspend fun endShopping() = Unit

            override suspend fun clearLocalState() = Unit

            override fun resumeSync() {
                steps += "resume"
            }

            override suspend fun rebuild() = Unit
        }

    // `prepare` et `abandon` ne parlent pas au serveur.
    private val gateway =
        Proxy.newProxyInstance(RemoteGateway::class.java.classLoader, arrayOf(RemoteGateway::class.java)) { _, m, _ ->
            throw UnsupportedOperationException(m.name)
        } as RemoteGateway

    private val controller =
        AccountSignOutController(
            AccountSignOut(
                gateway,
                LocalDataPurge(db, InMemorySyncCursors()),
                host,
                InMemoryAccountSignOutFlag(),
                isOnline = { true },
                flush = {},
                unsent = { 2 },
            ),
            scope,
        )

    @Before
    fun setUp() = Dispatchers.setMain(Dispatchers.Unconfined)

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        scope.cancel()
        db.close()
    }

    /** Mineur 1 : écran quitté pendant la confirmation, la synchro arrêtée par `prepare` reprend. */
    @Test
    fun leavingTheScreenBeforeConfirmingResumesTheSync() {
        val model = AccountViewModel(session = null, signOut = controller, onSignIn = {})
        model.actions.onSignOutRequest()
        assertTrue(model.state.value.confirmingSignOut)
        assertEquals(2, model.state.value.unsentChanges)
        assertEquals(listOf("suspend"), steps)

        model.release()

        assertEquals(listOf("suspend", "resume"), steps)
        // Une seule reprise, même si la fermeture suit.
        model.actions.onSignOutDismiss()
        assertEquals(listOf("suspend", "resume"), steps)
    }
}
