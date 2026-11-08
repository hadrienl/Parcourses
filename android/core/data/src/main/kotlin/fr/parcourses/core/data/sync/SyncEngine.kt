package fr.parcourses.core.data.sync

import android.util.Log
import fr.parcourses.core.data.outbox.CheckPayload
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.outbox.ServerClock
import fr.parcourses.core.data.outbox.VisitClosePayload
import fr.parcourses.core.data.outbox.carriesDeviceTime
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.VisitAccess
import fr.parcourses.core.network.dto.VisitInsert
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.SerializationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.random.Random
import kotlin.time.Clock
import kotlin.time.Instant

/** Ce que la synchronisation a besoin de savoir de son environnement. */
class SyncDependencies(
    val now: () -> Instant = { Clock.System.now() },
    val jitter: () -> Double = { Random.nextDouble(JITTER_MIN, JITTER_MAX) },
    val isOnline: () -> Boolean = { true },
) {
    private companion object {
        const val JITTER_MIN = 0.8
        const val JITTER_MAX = 1.2
    }
}

/**
 * Vide la file puis descend les données. Une seule passe à la fois. Port de `SyncEngine` d'iOS : mêmes règles,
 * mêmes délais ([SyncRetryPolicy]). La différence est le déclencheur : ici le moteur est passif et c'est
 * WorkManager (`ListSyncWorker`) qui l'appelle ; [drain] renvoie l'instant où il faut le rappeler.
 *
 * Une erreur sans réponse exploitable (réseau, 5xx, 401) arrête la passe avec un délai global et ne consomme
 * aucun essai de l'entrée : couper le réseau ne doit jamais rapprocher une coche de l'abandon.
 *
 * Une ligne qui reçoit une erreur serveur retient d'abord toute la file, comme une panne. Passé
 * [SyncRetryPolicy.serverFailureGrace], elle est mise de côté, sans jamais passer en `FAILED`.
 *
 * Un nouveau compte déclenche [AccountRekey] avant tout envoi, puis `acknowledgeAccount`. Un stockage chiffré
 * verrouillé n'est pas une session perdue : [RemoteError.SecureStorageLocked] n'est qu'un délai.
 */
@Suppress("TooManyFunctions", "LargeClass")
class SyncEngine(
    private val gateway: RemoteGateway,
    private val db: ParcoursesDatabase,
    private val cursors: SyncCursors,
    private val classify: (String) -> PulledItemClassification,
    private val dependencies: SyncDependencies = SyncDependencies(),
) {
    private val store = SyncStore(db)
    private val rekey = AccountRekey(db)
    private val reconciliation = OutboxReconciliation(db)
    private val passLock = Mutex()
    private val _remaps = MutableSharedFlow<IdentifierRemap>(extraBufferCapacity = REMAP_BUFFER)

    /** Anciens identifiants vers nouveaux après une reprise de compte : les écrans ouverts s'y alignent. */
    val remaps: SharedFlow<IdentifierRemap> = _remaps

    /** Pas de session valide : seule une passe forcée (`pull`) tente d'en retrouver une. */
    @Volatile
    var isWaitingForSession = false
        private set

    // Demandes posées de n'importe quel thread, lues par la boucle de passes.
    private val isRunRequested = AtomicBoolean(false)
    private val isPullRequested = AtomicBoolean(false)

    // Le reste n'est touché que sous [passLock].
    private var isServerOutageSuspected = false
    private var needsAccountRecovery = false
    private var needsReconciliation = true
    private var transientFailures = 0
    private var backoffUntil: Instant? = null
    private var pullBackoffUntil: Instant? = null
    private var lastPull: Instant? = null
    private var resolutionAttempts = mutableMapOf<String, String>()
    private var resolutionBackoffUntil: Instant? = null

    /** Une session valide est peut-être revenue. */
    fun resume() {
        isWaitingForSession = false
        request(pull = true)
    }

    /** Note qu'une passe est due. `pull` : lancement, premier plan, retour du réseau ; lève aussi le délai. */
    fun request(pull: Boolean = false) {
        isRunRequested.set(true)
        if (pull) isPullRequested.set(true)
    }

    /**
     * Passes jusqu'à ce qu'il n'y ait plus rien de demandé. Renvoie l'instant où rappeler le moteur (entrée
     * différée, délai d'erreur, descente à refaire), `null` s'il n'y a rien à attendre.
     */
    suspend fun drain(pull: Boolean = false): Instant? {
        request(pull)
        return passLock.withLock {
            try {
                while (isRunRequested.getAndSet(false) && currentCoroutineContext().isActive) {
                    pass(pull = isPullRequested.getAndSet(false))
                }
            } catch (e: CancellationException) {
                // Une passe interrompue n'est pas perdue : la prochaine reprend.
                isRunRequested.set(true)
                throw e
            }
            nextWake()
        }
    }

    // region Passe

    @Suppress("ReturnCount")
    private suspend fun pass(pull: Boolean) {
        var pullDue = pull
        reconcileQueueIfNeeded()
        // Une descente demandée reste due si la passe s'arrête avant elle.
        if (!dependencies.isOnline()) return deferPull(pullDue)
        if (isWaitingForSession) {
            // Seule une passe forcée (premier plan, réseau) tente de retrouver une session.
            if (!pullDue) return
            if (!restoreSession()) return deferPull(true)
        }
        if (backoffUntil?.let { it > dependencies.now() } == true) return deferPull(pullDue)
        when (prepareAccount()) {
            AccountState.Stopped -> return deferPull(pullDue)
            AccountState.Recovered -> pullDue = true
            AccountState.Ready -> Unit
        }
        // Avant l'envoi : l'article et ses coches en file partent avec leur produit.
        resolveProducts()
        val sent = sendQueue() ?: return deferPull(pullDue)
        transientFailures = 0
        backoffUntil = null
        val now = dependencies.now()
        val isPullDue = sent > 0 && (lastPull?.let { now - it >= SyncRetryPolicy.pullAfterSendInterval } ?: true)
        if (!pullDue && !isPullDue) return
        if (pullBackoffUntil?.let { it > now } == true) isPullRequested.set(true) else pullAll(now)
    }

    private fun deferPull(pull: Boolean) {
        if (pull) isPullRequested.set(true)
    }

    /**
     * Au lancement, avant tout envoi : une donnée `PENDING` sans entrée active reçoit la sienne. Purement local,
     * donc aussi hors ligne. Un échec local laisse l'indicateur levé : la passe suivante recommence.
     */
    private suspend fun reconcileQueueIfNeeded() {
        if (needsReconciliation && reconcileQueue()) needsReconciliation = false
    }

    private suspend fun reconcileQueue(): Boolean =
        try {
            val queued = reconciliation.run(dependencies.now())
            if (queued > 0) Log.i(TAG, "File réconciliée : $queued entrée(s) ajoutée(s)")
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Réconciliation impossible : ${e.javaClass.simpleName}")
            false
        }

    private suspend fun restoreSession(): Boolean =
        try {
            gateway.ensureSession(null)
            isWaitingForSession = false
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            stop(e)
            false
        }

    private enum class AccountState { Ready, Recovered, Stopped }

    /**
     * Les données locales correspondent-elles au compte de la session ? Le curseur couvre un stockage de session
     * vidé, où la passerelle n'a plus de dernier compte à comparer.
     */
    private suspend fun prepareAccount(): AccountState {
        try {
            if (!needsAccountRecovery) {
                val id = gateway.currentAccountId()
                val known = cursors.accountId
                if (known != null && known != id) {
                    needsAccountRecovery = true
                } else {
                    cursors.accountId = id
                    return AccountState.Ready
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: RemoteError.AccountChanged) {
            needsAccountRecovery = true
        } catch (e: Exception) {
            stop(e)
            return AccountState.Stopped
        }
        return recoverAccount()
    }

    /**
     * Ordre important pour la reprise après un arrêt : tant que `acknowledgeAccount` n'a pas écrit, chaque requête
     * lève [RemoteError.AccountChanged], rien ne part, et l'opération recommence depuis le début. Le seul chemin
     * qui acquitte le compte est celui-ci, après la réidentification : il n'y a pas de « annuler ».
     */
    private suspend fun recoverAccount(): AccountState =
        try {
            // D'abord le compte : sans session établie (stockage verrouillé compris), on ne touche à rien.
            val id = gateway.sessionAccountId()
            val remap = rekey.run(dependencies.now())
            _remaps.tryEmit(remap)
            cursors.lists = null
            cursors.items = null
            cursors.accountId = id
            gateway.acknowledgeAccount(id)
            needsAccountRecovery = false
            isWaitingForSession = false
            lastPull = null
            pullBackoffUntil = null
            Log.i(TAG, "Données locales réidentifiées pour un nouveau compte")
            AccountState.Recovered
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            needsAccountRecovery = true
            stop(e, recovering = true)
            AccountState.Stopped
        }

    /** Classe une erreur de session ou de transport. */
    private fun stop(
        error: Throwable,
        recovering: Boolean = false,
    ): Next {
        when (error) {
            is RemoteError.AccountChanged -> {
                needsAccountRecovery = true
                isWaitingForSession = false
                // Pendant la reprise, une nouvelle erreur attend le délai : pas de boucle serrée.
                if (recovering) registerTransientFailure() else isRunRequested.set(true)
            }

            is RemoteError.Unauthorized -> {
                isWaitingForSession = true
            }

            else -> {
                registerTransientFailure()
            }
        }
        return Next.Stop
    }

    /** `null` si le serveur confirme la session. Une session perdue ne doit jamais produire de `FAILED`. */
    private suspend fun confirmSession(): Next? =
        try {
            gateway.verifySession()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            stop(e)
        }

    private fun registerTransientFailure() {
        transientFailures += 1
        backoffUntil = dependencies.now() + SyncRetryPolicy.delay(transientFailures, dependencies.jitter())
    }

    // endregion

    // region Envoi

    private enum class Next { Proceed, Stop }

    /** Nombre de lots envoyés, `null` si la passe s'est arrêtée sur une erreur passagère. */
    private suspend fun sendQueue(): Int? {
        var sent = 0
        val singleChecks = mutableSetOf<String>()
        try {
            while (currentCoroutineContext().isActive) {
                val work = store.nextWork(dependencies.now(), singleChecks) ?: return sent
                try {
                    send(work)
                    store.complete(work)
                    isWaitingForSession = false
                    releaseParkedIfRecovered()
                    sent += 1
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Charge utile illisible : la rejouer ne changerait rien.
                    val remote =
                        when (e) {
                            is RemoteError -> e
                            is SerializationException -> RemoteError.Rejected("payload", e)
                            else -> RemoteError.Unexpected(e)
                        }
                    if (handle(remote, work, singleChecks) == Next.Stop) return null
                }
            }
            return null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Écriture locale impossible : la file reste telle quelle, on réessaiera.
            Log.e(TAG, "Passe interrompue : ${e.javaClass.simpleName}")
            registerTransientFailure()
            return null
        }
    }

    private suspend fun send(work: OutboxWork) {
        val payload = work.payloads.first()
        when (work.kind) {
            OutboxKind.UpsertList -> {
                gateway.saveList(OutboxCoding.decode(ListUpsert.serializer(), payload))
            }

            OutboxKind.DeleteList -> {
                gateway.deleteList(parse(work.entityId))
            }

            OutboxKind.UpsertItem -> {
                gateway.saveItem(OutboxCoding.decode(ListItemUpsert.serializer(), payload))
            }

            OutboxKind.DeleteItem -> {
                gateway.deleteItem(parse(work.entityId))
            }

            OutboxKind.CreateVisit -> {
                gateway.createVisit(OutboxCoding.decode(VisitInsert.serializer(), payload))
            }

            OutboxKind.InsertChecks -> {
                val uploads = work.payloads.mapNotNull { OutboxCoding.decode(CheckPayload.serializer(), it).upload() }
                if (uploads.size != work.payloads.size) throw RemoteError.Rejected("check-without-target")
                gateway.insertChecks(uploads)
            }

            OutboxKind.CloseVisit -> {
                val close = OutboxCoding.decode(VisitClosePayload.serializer(), payload)
                gateway.closeVisit(parse(close.visitId), close.endedAt)
            }
        }
    }

    private fun parse(id: String) = kotlin.uuid.Uuid.parse(id)

    private suspend fun releaseParkedIfRecovered() {
        if (!isServerOutageSuspected) return
        isServerOutageSuspected = false
        store.releaseParked(dependencies.now())
    }

    @Suppress("CyclomaticComplexMethod")
    private suspend fun handle(
        error: RemoteError,
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Next =
        when (error) {
            is RemoteError.AccountChanged, is RemoteError.Unauthorized, is RemoteError.Network,
            is RemoteError.SecureStorageLocked,
            -> {
                stop(error)
            }

            is RemoteError.Unexpected -> {
                handleServerFailure(error, work, singleChecks)
            }

            is RemoteError.Server -> {
                if (error.isCappedClientFailure) {
                    retryCapped(error, work, singleChecks)
                } else {
                    handleServerFailure(error, work, singleChecks)
                }
            }

            is RemoteError.DependencyMissing -> {
                retryCapped(error, work, singleChecks)
            }

            is RemoteError.UnknownCategory -> {
                handleUnknownCategory(error, work, singleChecks)
            }

            is RemoteError.Forbidden -> {
                handleForbidden(work)
            }

            is RemoteError.Constraint, is RemoteError.Rejected -> {
                handleRefusal(error, work, singleChecks)
            }
        }

    private suspend fun handleUnknownCategory(
        error: RemoteError,
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Next {
        if (split(work, singleChecks)) return Next.Proceed
        val delay = SyncRetryPolicy.unknownCategoryDelay * dependencies.jitter()
        store.postpone(work, work.attempts + 1, dependencies.now() + delay, error.toString())
        return Next.Proceed
    }

    private suspend fun handleRefusal(
        error: RemoteError,
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Next {
        if (error is RemoteError.Constraint && error.code == CLOCK_CONSTRAINT && work.kind.carriesDeviceTime) {
            when (correctClock(work)) {
                ClockOutcome.Corrected -> {
                    return Next.Proceed
                }

                ClockOutcome.Stopped -> {
                    return Next.Stop
                }

                ClockOutcome.NoServerTime -> {
                    // Rien ne prouve que la ligne soit fautive : de côté, sans essai consommé, jamais `FAILED`.
                    val delay = SyncRetryPolicy.parkedRetryDelay * dependencies.jitter()
                    store.postpone(work, work.attempts, dependencies.now() + delay, "$error, heure du serveur inconnue")
                    return Next.Proceed
                }

                ClockOutcome.NotAhead -> {
                    Unit
                }
            }
        }
        if (split(work, singleChecks)) return Next.Proceed
        failDefinitively(work, error.toString())
        return Next.Proceed
    }

    /**
     * La panne retient la file jusqu'à la fin du délai : une panne générale ne doit rien mettre de côté trop tôt.
     * Le départ de la panne n'est effacé que par un succès : une ligne déjà mise de côté y retourne dès son échec.
     */
    private suspend fun handleServerFailure(
        error: RemoteError,
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Next {
        val now = dependencies.now()
        val since = store.markServerFailure(work, now, error.toString())
        if (now - since < SyncRetryPolicy.serverFailureGrace) {
            isServerOutageSuspected = true
            return stop(error)
        }
        if (split(work, singleChecks)) return Next.Proceed
        val delay = SyncRetryPolicy.parkedRetryDelay * dependencies.jitter()
        store.postpone(work, work.attempts, now + delay, error.toString())
        Log.i(TAG, "Entrée mise de côté (${work.kind.raw})")
        return Next.Proceed
    }

    private enum class ClockOutcome { Corrected, NotAhead, NoServerTime, Stopped }

    /**
     * `23514` : seul un horodatage trop loin dans le futur se corrige. Tout le lot d'un coup, sans essai consommé :
     * la date renvoyée n'est jamais après l'heure du serveur, le prochain refus éventuel a donc une autre cause.
     */
    private suspend fun correctClock(work: OutboxWork): ClockOutcome {
        val serverNow =
            try {
                gateway.serverDate()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                stop(e)
                return ClockOutcome.Stopped
            } ?: return ClockOutcome.NoServerTime
        val clock = ServerClock(serverNow = serverNow, deviceNow = dependencies.now())
        return if (store.correctClock(work, clock)) ClockOutcome.Corrected else ClockOutcome.NotAhead
    }

    private suspend fun retryCapped(
        error: RemoteError,
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Next {
        if (split(work, singleChecks)) return Next.Proceed
        return capAttempts(error, work, SyncRetryPolicy.MAX_DEPENDENCY_ATTEMPTS)
    }

    /** Compte un refus sur tout le lot : abandon au plafond, délai croissant sinon. */
    private suspend fun capAttempts(
        error: RemoteError,
        work: OutboxWork,
        limit: Int,
    ): Next {
        val attempts = work.attempts + 1
        if (attempts >= limit) {
            confirmSession()?.let { return it }
            failDefinitively(work, "$error, plafond atteint")
            return Next.Proceed
        }
        val delay = SyncRetryPolicy.delay(attempts, dependencies.jitter())
        store.postpone(work, attempts, dependencies.now() + delay, error.toString())
        return Next.Proceed
    }

    /** Un lot refusé pour une raison propre à une ligne repart ligne à ligne, sans consommer d'essai. */
    private fun split(
        work: OutboxWork,
        singleChecks: MutableSet<String>,
    ): Boolean {
        if (work.kind != OutboxKind.InsertChecks || work.entryIds.size <= 1) return false
        val first =
            runCatching { OutboxCoding.decode(CheckPayload.serializer(), work.payloads[0]) }.getOrNull() ?: return false
        singleChecks += first.visitId
        return true
    }

    private suspend fun failDefinitively(
        work: OutboxWork,
        reason: String,
    ) {
        if (work.kind == OutboxKind.CreateVisit) store.failVisit(work.entityId, reason) else store.fail(work, reason)
    }

    /** `42501` ne signifie pas la même chose selon l'entrée. */
    private suspend fun handleForbidden(work: OutboxWork): Next =
        when (work.kind) {
            OutboxKind.CreateVisit -> handleForbiddenVisit(work)
            OutboxKind.InsertChecks -> handleForbiddenChecks(work)
            OutboxKind.UpsertItem -> if (waitForList(work)) Next.Proceed else failForbidden(work)
            else -> failForbidden(work)
        }

    private suspend fun handleForbiddenVisit(work: OutboxWork): Next {
        if (waitForList(work)) return Next.Proceed
        // Liste supprimée entre-temps : la visite reste utile au graphe, on la renvoie sans liste.
        val row = OutboxCoding.decode(VisitInsert.serializer(), work.payloads[0])
        if (row.listId != null) {
            store.removeListFromCreation(work)
            return Next.Proceed
        }
        confirmSession()?.let { return it }
        store.failVisit(work.entityId, "42501 sur une visite sans liste")
        return Next.Proceed
    }

    private suspend fun failForbidden(work: OutboxWork): Next {
        confirmSession()?.let { return it }
        store.fail(work, OutboxReconciliation.FORBIDDEN_REASON)
        return Next.Proceed
    }

    /**
     * `42501` sur un article dont la liste n'est pas encore arrivée au serveur : la RLS ne voit pas la liste, ce
     * n'est pas un refus de l'article (ni de la visite). Il attend la liste, sans essai consommé ; la liste est
     * remise en file si elle n'y est plus. Faux si la liste est reçue (ou abandonnée) : le refus est alors bien
     * celui de l'article.
     */
    private suspend fun waitForList(work: OutboxWork): Boolean {
        val listId = store.unsentListId(work) ?: return false
        if (!reconcileQueue()) return false
        val delay = SyncRetryPolicy.listWaitDelay * dependencies.jitter()
        store.postpone(
            work,
            work.attempts,
            dependencies.now() + delay,
            "${OutboxReconciliation.FORBIDDEN_REASON}, liste $listId pas encore reçue",
        )
        return true
    }

    /**
     * Visite close et à nous : coche « reçue » (contrat hors ligne). Visite invisible : elle vient d'un autre
     * compte et les coches ne sont arrivées nulle part : elles restent en local en `FAILED`, jamais marquées
     * reçues. Ne pas mettre toute la file en pause : une seule visite la bloquerait pour toujours.
     */
    private suspend fun handleForbiddenChecks(work: OutboxWork): Next {
        val first = OutboxCoding.decode(CheckPayload.serializer(), work.payloads[0])
        val access =
            try {
                gateway.visitAccess(parse(first.visitId))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                return stop(e)
            }
        when (access) {
            VisitAccess.Closed -> {
                Log.i(TAG, "Coche tardive considérée comme reçue : visite déjà close")
                store.complete(work)
            }

            VisitAccess.NotVisible -> {
                confirmSession()?.let { return it }
                store.failVisit(first.visitId, "visite invisible pour ce compte")
            }

            // Inexplicable d'après la RLS : ni perdue tout de suite, ni rejouée sans fin. Le refus porte sur la
            // visite, pas sur une ligne : découper le lot n'y changerait rien.
            VisitAccess.Open -> {
                return capAttempts(RemoteError.Forbidden(), work, SyncRetryPolicy.MAX_DEPENDENCY_ATTEMPTS)
            }
        }
        return Next.Proceed
    }

    // endregion

    // region Produits

    /**
     * Donne un produit partagé aux articles saisis librement (apprentissage sans catalogue). Un échec ne retient
     * jamais la file : la résolution attend seule, et l'envoi décide du délai global s'il échoue aussi.
     */
    private suspend fun resolveProducts() {
        val now = dependencies.now()
        if (resolutionBackoffUntil?.let { it > now } == true) return
        try {
            while (currentCoroutineContext().isActive) {
                val candidates = store.productCandidates(resolutionAttempts, SyncRetryPolicy.MAX_RESOLUTION_BATCH)
                if (candidates.isEmpty()) break
                val rows = gateway.resolveProducts(candidates.map { it.request })
                if (rows.size != candidates.size) throw RemoteError.Unexpected()
                candidates.forEach { resolutionAttempts[it.itemId] = it.label }
                val matches = candidates.zip(rows).mapNotNull { (candidate, row) -> ProductMatch.of(candidate, row) }
                if (matches.isEmpty()) continue
                if (ProductResolution.apply(db, matches, now)) Log.d(TAG, "Produits résolus : ${matches.size}")
            }
            resolutionBackoffUntil = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.i(TAG, "Résolution des produits reportée : ${e.javaClass.simpleName}")
            val delay = SyncRetryPolicy.resolutionDelay(e)
            resolutionBackoffUntil = now + delay * dependencies.jitter()
        }
    }

    // endregion

    // region Descente

    private suspend fun pullAll(now: Instant) {
        try {
            val lists = gateway.fetchLists(cursors.lists)
            val items = gateway.fetchItems(cursors.items)
            val listsMerge = store.mergeLists(lists)
            val itemsMerge = store.mergeItems(items, classify)
            cursors.lists = later(cursors.lists, listsMerge.cursor)
            cursors.items = later(cursors.items, itemsMerge.cursor)
            if (cursors.catalog?.let { now - it >= SyncRetryPolicy.catalogInterval } != false) {
                store.applyCategories(gateway.fetchCategories())
                store.replaceProducts(gateway.fetchProducts())
                cursors.catalog = now
            }
            lastPull = now
            pullBackoffUntil = null
            releaseParkedIfRecovered()
            isWaitingForSession = false
        } catch (e: CancellationException) {
            isPullRequested.set(true)
            throw e
        } catch (e: Exception) {
            isPullRequested.set(true)
            Log.i(TAG, "Descente reportée : ${e.javaClass.simpleName}")
            when (e) {
                is RemoteError.AccountChanged, is RemoteError.Unauthorized -> stop(e)

                // N'arrête pas l'envoi : seul un nouvel essai de descente attend.
                else -> pullBackoffUntil = now + SyncRetryPolicy.pullRetryInterval
            }
        }
    }

    private fun later(
        first: Instant?,
        second: Instant?,
    ): Instant? = listOfNotNull(first, second).maxOrNull()

    // endregion

    // region Réveil

    /** Quand rappeler le moteur : prochaine entrée différée, délai d'erreur, descente à refaire. */
    private suspend fun nextWake(): Instant? {
        if (!dependencies.isOnline() || isWaitingForSession) return null
        val date = dependencies.now()
        // Demande arrivée après la dernière lecture de la boucle (WorkManager `KEEP` ne l'a pas relancée).
        if (isRunRequested.get()) return date
        // Une entrée déjà échue et libre compte : la passe a pu s'arrêter avant elle.
        val next = if (store.nextWork(date) != null) date else store.nextDueDate(date)
        val pullDate = if (isPullRequested.get()) (pullBackoffUntil ?: date) else null
        var target = listOfNotNull(next, pullDate).minOrNull()
        backoffUntil?.let { target = maxOf(target ?: it, it) }
        return target
    }

    // endregion

    private companion object {
        const val TAG = "SyncEngine"
        const val CLOCK_CONSTRAINT = "23514"
        const val REMAP_BUFFER = 8
    }
}
