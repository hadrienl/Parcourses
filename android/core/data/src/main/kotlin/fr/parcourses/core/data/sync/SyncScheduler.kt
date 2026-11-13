package fr.parcourses.core.data.sync

import android.content.Context
import android.util.Log
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
import androidx.work.await
import kotlinx.coroutines.CancellationException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
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

    /** Le travail de synchronisation [workId] commence : appelé par le worker avant sa passe. */
    fun runStarted(workId: UUID) = Unit

    /**
     * Annule tous les travaux de synchronisation (suppression du compte, #68) : rend la main quand l'annulation est
     * enregistrée. Une passe en cours est interrompue ; `SyncEngine.suspend` attend sa fin.
     */
    suspend fun cancelAll()
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
     * Dernière demande mise en file et pas encore commencée : `null` s'il n'y en a pas. En mémoire : après la mort
     * du processus, la demande suivante s'ajoute à la file de WorkManager, ce qui ne coûte qu'une passe vide.
     */
    private var waiting: Waiting? = null
    private val lock = Any()

    /** [id] : le travail ; [pull] : vrai si lui ou une demande d'avant dans la chaîne descend. */
    private class Waiting(
        val id: UUID,
        val pull: Boolean,
    )

    /**
     * `APPEND_OR_REPLACE` (#54) : une demande faite pendant une passe, même après sa dernière vérification, ajoute
     * une passe derrière elle, au lieu d'être ignorée comme avec `KEEP` jusqu'au périodique. Pour que la chaîne ne
     * s'allonge pas à chaque écriture hors ligne, une demande pas encore commencée suffit : le moteur lit lui-même
     * ce qui est dû au démarrage. Sauf pour une descente demandée après une demande sans descente : elle part avec
     * son propre travail, et ne vit donc pas seulement dans la mémoire du moteur.
     *
     * Le worker ne lève jamais (voir [ListSyncWorker.doWork]) : une chaîne ne peut pas échouer et emporter avec
     * elle la demande ajoutée derrière. Si WorkManager refuse l'ajout lui-même, la demande suivante est remise en
     * file au lieu d'attendre un démarrage qui ne viendra pas.
     */
    override fun enqueue(pull: Boolean) {
        val request =
            OneTimeWorkRequestBuilder<ListSyncWorker>()
                .setConstraints(connected)
                .setInputData(Data.Builder().putBoolean(ListSyncWorker.KEY_PULL, pull).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
                .build()
        synchronized(lock) {
            val queued = waiting
            if (queued != null && (queued.pull || !pull)) return
            waiting = Waiting(request.id, pull || queued?.pull == true)
        }
        val operation = workManager.enqueueUniqueWork(UNIQUE_NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        operation.result.addListener(
            {
                val failed = runCatching { operation.result.get() }.isFailure
                if (failed) forget(request.id)
            },
            Runnable::run,
        )
    }

    /**
     * Une demande commence. Seule la dernière mise en file compte : une demande plus ancienne de la chaîne qui démarre
     * laisse la dernière en attente, qui verra tout ce qui arrive d'ici là.
     */
    override fun runStarted(workId: UUID) = forget(workId)

    private fun forget(workId: UUID) {
        synchronized(lock) { if (waiting?.id == workId) waiting = null }
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

    override suspend fun cancelAll() {
        synchronized(lock) { waiting = null }
        for (name in WORK_NAMES) workManager.cancelUniqueWork(name).await()
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

        /** Tous les travaux de synchronisation : il n'y a pas d'autre nom ni d'étiquette. */
        val WORK_NAMES = listOf(UNIQUE_NAME, WAKE_NAME, PERIODIC_NAME)
        private const val BACKOFF_SECONDS = 30L
        private val MIN_WAKE_DELAY: Duration = 1.seconds
        private val PERIOD: Duration = 6.hours
    }
}

/**
 * Une passe de synchronisation : pousse la file puis tire les changements (#10 §4.1). Réussit toujours : les
 * erreurs et leurs délais sont gérés par le moteur, qui indique quand le rappeler. Une panne locale imprévue (base
 * illisible) devient un rappel dans [FAILURE_RETRY] : un échec ferait échouer aussi la demande ajoutée derrière
 * (`APPEND_OR_REPLACE`), qui ne démarrerait jamais (#54).
 */
class ListSyncWorker(
    context: Context,
    params: WorkerParameters,
    private val engine: SyncEngine,
    private val scheduler: SyncScheduler,
    private val clock: () -> Instant = { Clock.System.now() },
) : CoroutineWorker(context, params) {
    @Suppress("TooGenericExceptionCaught") // jamais d'échec (voir plus haut) : la panne devient un rappel
    override suspend fun doWork(): Result {
        scheduler.runStarted(id)
        val wake: Instant? =
            try {
                passes()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Passe interrompue : ${e.javaClass.simpleName}")
                clock() + FAILURE_RETRY
            }
        if (wake != null) runCatching { scheduler.scheduleWake(wake) }
        return Result.success()
    }

    private suspend fun passes(): Instant? {
        var wake = engine.drain(pull = inputData.getBoolean(KEY_PULL, false))
        // Une écriture faite pendant la passe a ajouté une passe derrière celle-ci (`enqueue`) : on la fait tout de
        // suite, la suivante n'aura alors rien à faire.
        var rounds = 0
        while (engine.hasPendingRun && rounds++ < MAX_ROUNDS) wake = engine.drain()
        // Demande notée dans le moteur seulement, après la dernière vérification : un rappel immédiat la couvre.
        return if (engine.hasPendingRun) clock() else wake
    }

    companion object {
        const val KEY_PULL = "pull"
        private const val MAX_ROUNDS = 10
        private const val TAG = "ListSyncWorker"
        private val FAILURE_RETRY: Duration = 1.minutes
    }
}

/** Fabrique des workers de l'app : `Application` la passe à `Configuration.Builder().setWorkerFactory`. */
class SyncWorkerFactory(
    private val engine: () -> SyncEngine?,
    private val scheduler: SyncScheduler,
) : WorkerFactory() {
    @Suppress("ReturnCount")
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

    /** Suppression du compte (#68) : travaux annulés, puis le moteur s'arrête après la passe en cours. */
    suspend fun suspend() {
        scheduler.cancelAll()
        engine.suspend()
    }
}
