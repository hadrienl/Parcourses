package fr.parcourses.core.data

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import fr.parcourses.core.data.repository.RoomListRepository
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.data.sync.ListSyncWorker
import fr.parcourses.core.data.sync.SyncCoordinator
import fr.parcourses.core.data.sync.SyncEngine
import fr.parcourses.core.data.sync.SyncScheduler
import fr.parcourses.core.data.sync.SyncWorkerFactory
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

@RunWith(AndroidJUnit4::class)
class ListSyncWorkerTest : DataTest() {
    private class RecordingScheduler : SyncScheduler {
        val enqueued = mutableListOf<Boolean>()
        val wakes = mutableListOf<Instant>()
        var periodic = 0

        override fun enqueue(pull: Boolean) {
            enqueued += pull
        }

        override fun scheduleWake(at: Instant) {
            wakes += at
        }

        override fun schedulePeriodic() {
            periodic++
        }
    }

    private val gateway = FakeRemoteGateway()
    private val scheduler = RecordingScheduler()
    private val engine by lazy { SyncEngine(gateway, db, InMemorySyncCursors(), classify, dependencies) }

    private fun worker(pull: Boolean): ListenableWorker =
        TestListenableWorkerBuilder<ListSyncWorker>(ApplicationProvider.getApplicationContext<Context>())
            .setInputData(
                androidx.work.Data
                    .Builder()
                    .putBoolean(ListSyncWorker.KEY_PULL, pull)
                    .build(),
            ).setWorkerFactory(SyncWorkerFactory({ engine }, scheduler))
            .build()

    @Test
    fun theWorkerSendsTheQueueAndSucceeds() =
        runBlocking {
            RoomListRepository(db).createList("Courses", now)

            val result = worker(pull = false).startWork().get()

            assertEquals(ListenableWorker.Result.success(), result)
            assertEquals(1, gateway.callsOf("saveList").size)
            assertTrue(scheduler.wakes.isEmpty())
        }

    @Test
    fun theWorkerPullsWhenAskedAndSchedulesTheNextWakeOnAnError() =
        runBlocking {
            RoomListRepository(db).createList("Courses", now)
            gateway.failNext("saveList", RemoteError.Network())

            val result = worker(pull = true).startWork().get()

            // Les erreurs réseau ne font pas échouer le travail : le moteur dit quand revenir.
            assertEquals(ListenableWorker.Result.success(), result)
            assertEquals(listOf(now + 2.seconds), scheduler.wakes)
        }

    @Test
    fun theCoordinatorNotesTheRequestInTheEngineAndWakesWorkManager() =
        runBlocking {
            val coordinator = SyncCoordinator(engine, scheduler)
            coordinator.requestSync()
            coordinator.sessionDidChange()
            coordinator.start()
            assertEquals(listOf(false, true), scheduler.enqueued)
            assertEquals(1, scheduler.periodic)
            // La demande est prise en compte par la prochaine passe, avec descente.
            engine.drain()
            assertEquals(1, gateway.callsOf("fetchLists").size)
        }
}
