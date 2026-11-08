package fr.parcourses.core.data.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerFactory
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlin.time.toJavaDuration

/** Planification de la synchronisation. Le moteur ne sait pas comment il est réveillé. */
interface SyncScheduler {
    /** Une passe est due maintenant (dès que le réseau est là). */
    fun enqueue(pull: Boolean)

    /** Rappelle le moteur à [at] (entrée différée, délai d'erreur). Remplace tout rappel précédent. */
    fun scheduleWake(at: Instant)

    /** Filet de sécurité : une passe avec descente toutes les 6 h. */
    fun schedulePeriodic()
}

/** WorkManager : travail unique `lists-sync`, rappel différé `lists-sync-wake`, périodique 6 h. */
class WorkManagerSyncScheduler(
    context: Context,
    private val clock: () -> Instant = { Clock.System.now() },
) : SyncScheduler {
    // Paresseux : WorkManager lit la configuration de l'application à son premier accès.
    private val workManager by lazy { WorkManager.getInstance(context.applicationContext) }

    private val connected = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /**
     * `KEEP` : une demande déjà en attente suffit, le moteur lit lui-même ce qui est dû. Une demande qui arrive
     * pendant une passe est vue par le moteur, qui demande alors un rappel immédiat (voir [SyncEngine.drain]).
     */
    override fun enqueue(pull: Boolean) {
        val request =
            OneTimeWorkRequestBuilder<ListSyncWorker>()
                .setConstraints(connected)
                .setInputData(Data.Builder().putBoolean(ListSyncWorker.KEY_PULL, pull).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
                .build()
        workManager.enqueueUniqueWork(UNIQUE_NAME, ExistingWorkPolicy.KEEP, request)
    }

    override fun scheduleWake(at: Instant) {
        val delay = maxOf(MIN_WAKE_DELAY, at - clock())
        val request =
            OneTimeWorkRequestBuilder<ListSyncWorker>()
                .setConstraints(connected)
                .setInitialDelay(delay.toJavaDuration())
                .build()
        workManager.enqueueUniqueWork(WAKE_NAME, ExistingWorkPolicy.REPLACE, request)
    }

    override fun schedulePeriodic() {
        val request =
            PeriodicWorkRequestBuilder<ListSyncWorker>(PERIOD.inWholeHours, TimeUnit.HOURS)
                .setConstraints(
                    Constraints
                        .Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .setRequiresBatteryNotLow(true)
                        .build(),
                ).setInputData(Data.Builder().putBoolean(ListSyncWorker.KEY_PULL, true).build())
                .build()
        workManager.enqueueUniquePeriodicWork(PERIODIC_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
    }

    companion object {
        const val UNIQUE_NAME = "lists-sync"
        const val WAKE_NAME = "lists-sync-wake"
        const val PERIODIC_NAME = "lists-sync-periodic"
        private const val BACKOFF_SECONDS = 30L
        private val MIN_WAKE_DELAY: Duration = 1.seconds
        private val PERIOD: Duration = 6.hours
    }
}

/**
 * Une passe de synchronisation : pousse la file puis tire les changements (#10 §4.1). Réussit toujours : les
 * erreurs et leurs délais sont gérés par le moteur, qui indique quand le rappeler.
 */
class ListSyncWorker(
    context: Context,
    params: WorkerParameters,
    private val engine: SyncEngine,
    private val scheduler: SyncScheduler,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val wake = engine.drain(pull = inputData.getBoolean(KEY_PULL, false))
        wake?.let(scheduler::scheduleWake)
        return Result.success()
    }

    companion object {
        const val KEY_PULL = "pull"
    }
}

/** Fabrique des workers de l'app : `Application` la passe à `Configuration.Builder().setWorkerFactory`. */
class SyncWorkerFactory(
    private val engine: () -> SyncEngine?,
    private val scheduler: SyncScheduler,
) : WorkerFactory() {
    override fun createWorker(
        appContext: Context,
        workerClassName: String,
        workerParameters: WorkerParameters,
    ): androidx.work.ListenableWorker? {
        if (workerClassName != ListSyncWorker::class.java.name) return null
        val syncEngine = engine() ?: return null
        return ListSyncWorker(appContext, workerParameters, syncEngine, scheduler)
    }
}

/**
 * Point d'entrée des déclencheurs (écritures, premier plan, retour du réseau, session retrouvée) : note la demande
 * dans le moteur puis réveille WorkManager.
 */
class SyncCoordinator(
    private val engine: SyncEngine,
    private val scheduler: SyncScheduler,
) {
    /** Après chaque écriture qui allonge la file. */
    fun requestSync(pull: Boolean = false) {
        engine.request(pull)
        scheduler.enqueue(pull)
    }

    /** Une session valide est disponible (connexion anonyme faite, ou retrouvée). */
    fun sessionDidChange() {
        engine.resume()
        scheduler.enqueue(true)
    }

    fun start() = scheduler.schedulePeriodic()
}
