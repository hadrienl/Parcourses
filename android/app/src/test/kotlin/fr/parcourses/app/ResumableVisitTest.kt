package fr.parcourses.app

import android.app.Application
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import kotlin.time.Clock
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes

/**
 * Reprise au lancement (`AppContainer.resumableVisit`), testée directement (#54, A9) : une visite périmée est
 * **abandonnée** (close à sa dernière coche, introuvables remis à acheter), pas simplement close.
 */
@RunWith(AndroidJUnit4::class)
// Sans `ParcoursesApp` : son lancement ouvrirait la base native (absente de la JVM) et l'échec, non rattrapé,
// tomberait sur le test suivant qui utilise `runTest`.
@Config(application = Application::class)
class ResumableVisitTest {
    // Sans configuration Supabase : tout reste local. Base en mémoire, sur le pilote du système (pas le natif).
    private val container =
        AppContainer(RuntimeEnvironment.getApplication(), config = null) { context ->
            ParcoursesDatabaseFactory.createInMemory(context, Dispatchers.IO, AndroidSQLiteDriver())
        }
    private val store = "00000000-0000-4000-8000-000000000001"

    @After
    fun tearDown() = container.database.close()

    private suspend fun visitWithAMissingItem(lastCheckAgo: kotlin.time.Duration): Triple<String, String, String> {
        val now = Clock.System.now()
        val list = container.lists.createList("Courses", now - 3.hours)
        val milk = container.lists.addItem(list.id, "lait", "lait", null, null, "dairy", now - 3.hours)
        val bread = container.lists.addItem(list.id, "pain", "pain", null, null, "bakery", now - 3.hours)
        val visit = container.visits.startVisit(store, list.id, false, now - 3.hours)
        container.visits.checkItem(visit.id, milk.id, CheckSubject.Category("dairy"), now - lastCheckAgo)
        container.lists.setNotFound(bread.id, now - lastCheckAgo)
        return Triple(list.id, visit.id, bread.id)
    }

    @Test
    fun anActiveVisitIsResumedAndStaysOpen() =
        runBlocking {
            val (listId, visitId, bread) = visitWithAMissingItem(lastCheckAgo = 10.minutes)

            assertEquals(ResumableVisit(listId, store, visitId), container.resumableVisit())
            assertNull(container.visits.visit(visitId)?.endedAt)
            assertNotNull(
                container.database
                    .items()
                    .get(bread)
                    ?.notFoundAt,
            )
        }

    @Test
    fun aStaleVisitIsAbandonedAtItsLastCheckAndNothingIsResumed() =
        runBlocking {
            val (_, visitId, bread) = visitWithAMissingItem(lastCheckAgo = 1.hours)
            val lastCheck = container.visits.lastActivity(visitId)

            assertNull(container.resumableVisit())
            // Close à sa dernière coche, et non au lancement ; « garder » par défaut : le pain revient à acheter.
            assertEquals(lastCheck, container.visits.visit(visitId)?.endedAt)
            assertNull(
                container.database
                    .items()
                    .get(bread)
                    ?.notFoundAt,
            )
            assertNull(container.visits.openVisit())
        }

    @Test
    fun aVisitWhoseListIsGoneIsAbandonedEvenIfRecent() =
        runBlocking {
            val (listId, visitId, _) = visitWithAMissingItem(lastCheckAgo = 1.minutes)
            container.lists.deleteList(listId, Clock.System.now())

            assertNull(container.resumableVisit())
            assertNotNull(container.visits.visit(visitId)?.endedAt)
        }

    @Test
    fun withoutAnOpenVisitNothingIsResumed() =
        runBlocking {
            assertNull(container.resumableVisit())
        }
}
