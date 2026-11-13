package fr.parcourses.app

import android.app.Application
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionMarker
import fr.parcourses.core.data.account.AccountDeletionPhase
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import kotlin.time.Clock

/** `AppContainer.reset` et la reprise au lancement d'une suppression interrompue (#68), build sans Supabase. */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AppContainerResetTest {
    private val container =
        AppContainer(RuntimeEnvironment.getApplication(), config = null) { context ->
            ParcoursesDatabaseFactory.createInMemory(context, Dispatchers.IO, AndroidSQLiteDriver())
        }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After
    fun tearDown() {
        scope.cancel()
        container.deletionFlag.clear()
        container.database.close()
    }

    @Test
    fun resetRecreatesTheStatefulPartsAndAsksTheNavigationToRestart() {
        val live = container.liveUpdates
        val shopping = container.shopping
        assertFalse(container.consumeNavigationReset())

        container.reset()

        assertNotSame(live, container.liveUpdates)
        assertNotSame(shopping, container.shopping)
        assertEquals(1, container.generation.value)
        assertTrue(container.consumeNavigationReset())
        assertFalse(container.consumeNavigationReset())
    }

    @Test
    fun anInterruptedDeletionFinishesAtLaunchBeforeAnythingElse() =
        runBlocking {
            val now = Clock.System.now()
            val list = container.lists.createList("Courses", now)
            val milk = container.lists.addItem(list.id, "lait", "lait", null, null, "dairy", now)
            val visit = container.visits.startVisit("00000000-0000-4000-8000-000000000001", list.id, false, now)
            container.visits.checkItem(visit.id, milk.id, CheckSubject.Category("dairy"), now)
            container.deletionFlag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))
            // Le processus est mort pendant la suppression : la visite ouverte n'est pas reprise.
            assertNull(container.resumableVisit())

            container.start(scope)

            withTimeout(5_000) { container.accountDeletion.state.first { it == AccountDeletionState.Done } }
            assertFalse(container.deletionFlag.isPending)
            assertTrue(container.lists.lists().isEmpty())
            assertNull(container.visits.openVisit())
            assertTrue(container.categories.categories().isNotEmpty())
            assertTrue(container.consumeNavigationReset())
        }
}
