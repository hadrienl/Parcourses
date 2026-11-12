package fr.parcourses.core.data

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import androidx.work.testing.WorkManagerTestInitHelper
import fr.parcourses.core.data.sync.ListSyncWorker
import fr.parcourses.core.data.sync.WorkManagerSyncScheduler
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

/**
 * Politiques réelles de WorkManager (`WorkManagerTestInitHelper`) pour [WorkManagerSyncScheduler] (#54). Les passes
 * sont jouées par une sonde qui note chaque démarrage, comme [ListSyncWorker] le fait auprès du planificateur.
 */
@RunWith(AndroidJUnit4::class)
class SyncSchedulerPoliciesTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val now = Instant.fromEpochSeconds(1_000_000)
    private val scheduler = WorkManagerSyncScheduler(context, clock = { now })
    private val workManager by lazy { WorkManager.getInstance(context) }

    /** Valeur `pull` de chaque passe, dans l'ordre. */
    private val runs = Collections.synchronizedList(mutableListOf<Boolean>())

    /** La première passe attend ce verrou : elle reste « en cours » le temps du test. */
    private val firstRunRelease = CountDownLatch(1)
    private val firstRunStarted = CountDownLatch(1)
    private var holdsFirstRun = false

    private inner class Probe(
        appContext: Context,
        params: WorkerParameters,
    ) : Worker(appContext, params) {
        override fun doWork(): Result {
            scheduler.runStarted(id)
            runs += inputData.getBoolean(ListSyncWorker.KEY_PULL, false)
            if (runs.size == 1) {
                firstRunStarted.countDown()
                if (holdsFirstRun) {
                    check(firstRunRelease.await(WAIT_SECONDS, TimeUnit.SECONDS)) { "passe jamais libérée" }
                }
            }
            return Result.success()
        }
    }

    private val executor = Executors.newFixedThreadPool(2)

    @Before
    fun setUp() {
        val factory =
            object : WorkerFactory() {
                override fun createWorker(
                    appContext: Context,
                    workerClassName: String,
                    workerParameters: WorkerParameters,
                ): ListenableWorker? =
                    Probe(appContext, workerParameters).takeIf { workerClassName == ListSyncWorker::class.java.name }
            }
        val configuration =
            Configuration
                .Builder()
                .setWorkerFactory(factory)
                .setExecutor(executor)
                .build()
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            configuration,
            WorkManagerTestInitHelper.ExecutorsMode.PRESERVE_EXECUTORS,
        )
    }

    @After
    fun tearDown() {
        firstRunRelease.countDown()
        WorkManagerTestInitHelper.closeWorkDatabase()
        executor.shutdownNow()
    }

    private fun infos(name: String): List<WorkInfo> = workManager.getWorkInfosForUniqueWork(name).get()

    private fun requests() = infos(WorkManagerSyncScheduler.UNIQUE_NAME)

    /** Le réseau revient pour [info] : il démarre dès qu'il n'attend plus rien. */
    private fun connect(info: WorkInfo) {
        checkNotNull(WorkManagerTestInitHelper.getTestDriver(context)).setAllConstraintsMet(info.id)
        shadowOf(Looper.getMainLooper()).idle()
    }

    private fun awaitState(
        info: WorkInfo,
        vararg states: WorkInfo.State,
    ): WorkInfo {
        val deadline = System.currentTimeMillis() + WAIT_SECONDS * MILLIS
        while (System.currentTimeMillis() < deadline) {
            // WorkManager passe par le fil principal, en pause sous Robolectric.
            shadowOf(Looper.getMainLooper()).idle()
            val current = workManager.getWorkInfoById(info.id).get()!!
            if (current.state in states) return current
            Thread.sleep(STEP_MS)
        }
        error("${info.id} n'a pas atteint ${states.toList()}")
    }

    @Test
    fun requestsMadeBeforeTheWorkStartsShareOneRun() {
        repeat(3) { scheduler.enqueue(pull = false) }

        val queued = requests()
        assertEquals(1, queued.size)
        connect(queued.single())
        awaitState(queued.single(), WorkInfo.State.SUCCEEDED)
        assertEquals(listOf(false), runs)
    }

    @Test
    fun aPullAskedAfterAPlainRequestTravelsWithItsOwnWork() {
        scheduler.enqueue(pull = false)
        scheduler.enqueue(pull = true)
        // Une seconde descente n'ajoute rien : celle qui attend la fera.
        scheduler.enqueue(pull = true)
        scheduler.enqueue(pull = false)

        val queued = requests()
        assertEquals(2, queued.size)
        val (first, second) = queued.sortedBy { it.state != WorkInfo.State.ENQUEUED }
        connect(first)
        awaitState(first, WorkInfo.State.SUCCEEDED)
        // La première a démarré, mais la descente attend encore : une nouvelle demande n'ajoute rien.
        scheduler.enqueue(pull = false)
        assertEquals(2, requests().size)
        awaitState(second, WorkInfo.State.ENQUEUED)
        connect(second)
        awaitState(second, WorkInfo.State.SUCCEEDED)
        // La descente est dans les données du travail : elle survivrait à la mort du processus.
        assertEquals(listOf(false, true), runs)
    }

    @Test
    fun aRequestMadeWhileAPassRunsGetsAnotherPass() {
        holdsFirstRun = true
        scheduler.enqueue(pull = false)
        val first = requests().single()
        connect(first)
        awaitState(first, WorkInfo.State.RUNNING)
        assertTrue(firstRunStarted.await(WAIT_SECONDS, TimeUnit.SECONDS))

        // Écriture faite pendant la passe, après sa dernière vérification : `KEEP` l'ignorait.
        scheduler.enqueue(pull = false)
        val second = requests().single { it.id != first.id }
        firstRunRelease.countDown()
        awaitState(first, WorkInfo.State.SUCCEEDED)
        awaitState(second, WorkInfo.State.ENQUEUED)
        connect(second)
        awaitState(second, WorkInfo.State.SUCCEEDED)
        assertEquals(2, runs.size)
    }

    @Test
    fun aRequestAfterTheLastPassStartsANewOne() {
        scheduler.enqueue(pull = false)
        val first = requests().single()
        connect(first)
        awaitState(first, WorkInfo.State.SUCCEEDED)

        scheduler.enqueue(pull = true)
        val second = requests().single { it.id != first.id }
        connect(second)
        awaitState(second, WorkInfo.State.SUCCEEDED)
        assertEquals(listOf(false, true), runs)
    }

    @Test
    fun aWakeReplacesThePreviousOne() {
        scheduler.scheduleWake(now + 10.minutes)
        scheduler.scheduleWake(now + 1.minutes)

        val wakes = infos(WorkManagerSyncScheduler.WAKE_NAME)
        val active = wakes.filter { !it.state.isFinished }
        assertEquals(1, active.size)
        assertEquals(1.minutes.inWholeMilliseconds, active.single().initialDelayMillis)
        assertTrue(wakes.filter { it.state.isFinished }.all { it.state == WorkInfo.State.CANCELLED })
    }

    @Test
    fun thePeriodicWorkIsKeptAcrossLaunches() {
        scheduler.schedulePeriodic()
        val first = infos(WorkManagerSyncScheduler.PERIODIC_NAME).single()
        scheduler.schedulePeriodic()

        val periodic = infos(WorkManagerSyncScheduler.PERIODIC_NAME)
        assertEquals(listOf(first.id), periodic.map { it.id })
        assertTrue(periodic.single().periodicityInfo != null)
    }

    private companion object {
        const val WAIT_SECONDS = 10L
        const val MILLIS = 1_000L
        const val STEP_MS = 20L
    }
}
