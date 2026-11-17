package fr.parcourses.core.data.sharing

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.network.RealtimeEvent
import fr.parcourses.core.network.RealtimeSignalSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.uuid.Uuid

/**
 * Signaux temps réel du partage (#87 §6.2, §6.6), même nom qu'iOS. Un canal privé `user:<uid>` par appareil, seulement
 * pour un compte e-mail, ouvert au premier plan ([foreground]) et fermé en arrière-plan ([background]). Les signaux
 * reçus sont regroupés sur [window] (300 ms), puis traduits par `SharingDecisions.signalActions` : une descente
 * ([requestPull]), la relecture des invitations ([invitationReloads]) ou celle de la feuille « Partager » ouverte
 * ([sharingReloads]). À chaque (re)jonction du canal, une descente : les messages manqués ne sont pas rejoués. Puis
 * une seconde, [followUpDelay] (2,5 s) plus tard, comme iOS (`subscribedFollowUpDelay`) : une écriture d'un autre
 * membre faite juste après l'abonnement peut suivre la première descente sans que son signal soit acheminé : Realtime
 * froid perd un signal écrit juste après `SUBSCRIBED` (#123, `docs/data-model.md`, « Limite : signal perdu juste après
 * l'abonnement »). Aucune donnée ne passe par le signal : tout vient de la descente.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class RealtimeSignals(
    private val source: RealtimeSignalSource,
    /** Compte de la session ; `null` sans session (rien à ouvrir). */
    private val accountId: suspend () -> Uuid?,
    accountKind: Flow<AccountKind>,
    private val requestPull: () -> Unit,
    private val scope: CoroutineScope,
    private val window: Duration = WINDOW,
    /** Attente avant de rouvrir un canal tombé en erreur (refus, session illisible). */
    private val retryDelay: Duration = RETRY_DELAY,
    /** Envoi d'articles en cours ou récent vers cette liste ([RecentSends]) : son signal `items` est un écho. */
    private val isEcho: (String) -> Boolean = { false },
    /** Fenêtre de l'écho : un signal ignoré est rattrapé par une descente à sa fin. */
    private val echoWindow: Duration = RecentSends.ECHO_WINDOW,
    /** Seconde descente après chaque jonction ([SUBSCRIBED_FOLLOW_UP_DELAY]). */
    private val followUpDelay: Duration = SUBSCRIBED_FOLLOW_UP_DELAY,
) {
    private val isForeground = MutableStateFlow(false)
    private val session = MutableStateFlow(0)
    private val openSheets = MutableStateFlow<Map<String, Int>>(emptyMap())
    private val connected = MutableStateFlow(false)
    private val invitations = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    private val sharing = MutableSharedFlow<Set<String>>(extraBufferCapacity = BUFFER)

    private val lock = Mutex()
    private val pendingActions = mutableSetOf<SignalAction>()
    private val pendingSheets = mutableSetOf<String>()
    private var flushJob: Job? = null

    /** Descente programmée à la fin de la fenêtre d'écho, une à la fois. */
    private var echoPullJob: Job? = null

    /** Seconde descente due après la dernière jonction : une seule à la fois. */
    private var followUpPullJob: Job? = null

    /** Vrai tant que le canal est joint : pour les tests et le diagnostic, jamais pour décider d'un envoi. */
    val isConnected: StateFlow<Boolean> = connected.asStateFlow()

    /** Un signal `invitations` : relire `my_invitations`. */
    val invitationReloads: SharedFlow<Unit> = invitations.asSharedFlow()

    /** Un signal `members` ou `invitations` pendant que la feuille « Partager » de ces listes est ouverte. */
    val sharingReloads: SharedFlow<Set<String>> = sharing.asSharedFlow()

    init {
        scope.launch {
            combine(isForeground, accountKind.distinctUntilChanged(), session) { foreground, kind, generation ->
                Triple(foreground, kind, generation)
            }.collectLatest { (foreground, kind, _) ->
                if (foreground && kind == AccountKind.Email) listen() else close()
            }
        }
    }

    /** L'app passe au premier plan (`ProcessLifecycleOwner`, `ON_START`). */
    fun foreground() = isForeground.update { true }

    /** L'app passe en arrière-plan (`ON_STOP`) : le canal se ferme, le WebSocket avec lui. */
    fun background() = isForeground.update { false }

    /** Le compte de la session a changé (connexion, déconnexion) : le canal est rouvert pour le nouveau compte. */
    fun sessionChanged() = session.update { it + 1 }

    /** La feuille « Partager » de [listId] s'ouvre : ses signaux `members` et `invitations` la rechargent. */
    fun sharingSheetOpened(listId: String) = openSheets.update { it + (listId to (it[listId] ?: 0) + 1) }

    fun sharingSheetClosed(listId: String) =
        openSheets.update { sheets ->
            val count = (sheets[listId] ?: 0) - 1
            if (count > 0) sheets + (listId to count) else sheets - listId
        }

    @Suppress("TooGenericExceptionCaught") // un canal qui tombe est rouvert après un délai ; l'annulation est relancée
    private suspend fun listen() {
        // Canal rouvert (autre compte) : la seconde descente de l'ancienne jonction n'a plus lieu d'être, comme à la
        // fermeture ; la jonction du nouveau canal en programme une.
        lock.withLock {
            followUpPullJob?.cancel()
            followUpPullJob = null
        }
        while (true) {
            val id =
                try {
                    accountId()
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                } ?: return close()
            try {
                source.signals(id).collect { event -> receive(event) }
            } catch (e: CancellationException) {
                connected.value = false
                throw e
            } catch (e: Exception) {
                Log.i(TAG, "Canal temps réel fermé : ${e.javaClass.simpleName}")
            }
            connected.value = false
            delay(retryDelay)
        }
    }

    private suspend fun close() {
        connected.value = false
        lock.withLock {
            flushJob?.cancel()
            flushJob = null
            echoPullJob?.cancel()
            echoPullJob = null
            // Sans canal, plus rien à rattraper : le retour au premier plan rouvre le canal, et sa jonction redescend.
            followUpPullJob?.cancel()
            followUpPullJob = null
            pendingActions.clear()
            pendingSheets.clear()
        }
    }

    private suspend fun receive(event: RealtimeEvent) {
        when (event) {
            RealtimeEvent.Subscribed -> {
                connected.value = true
                // (Re)jonction : une descente, regroupée avec les signaux qui arrivent en même temps, puis une seconde
                // 2,5 s plus tard pour ce qui a été écrit entre la première et l'acheminement des signaux.
                enqueue(listOf(SignalAction.Pull), null)
                // Une seule seconde descente en attente : une nouvelle jonction remplace la précédente.
                lock.withLock {
                    followUpPullJob?.cancel()
                    followUpPullJob =
                        scope.launch {
                            delay(followUpDelay)
                            // Comme `pullNow()` sur iOS : la descente de fin de fenêtre d'écho n'a plus lieu d'être.
                            lock.withLock {
                                echoPullJob?.cancel()
                                echoPullJob = null
                            }
                            requestPull()
                        }
                }
            }

            is RealtimeEvent.Changed -> {
                val listId = event.listId?.toString()
                // Écho probable de mes propres envois : pas de descente tout de suite. Un vrai changement d'un autre
                // membre a pu arriver dans la fenêtre : une seule descente le rattrape à sa fin.
                if (event.kind == ITEMS && listId != null && isEcho(listId)) return pullAfterEchoWindow()
                val sheets = openSheets.value.keys
                // Signal d'invitation sans liste : vaut pour toute feuille ouverte.
                val open = if (listId == null) sheets.isNotEmpty() else listId in sheets
                val targets = if (listId == null) sheets else setOf(listId)
                enqueue(SharingDecisions.signalActions(event.kind, open), targets.takeIf { open })
            }
        }
    }

    private suspend fun pullAfterEchoWindow() {
        lock.withLock {
            if (echoPullJob?.isActive == true) return
            echoPullJob =
                scope.launch {
                    delay(echoWindow)
                    enqueue(listOf(SignalAction.Pull), null)
                }
        }
    }

    /** Première action d'une rafale : la fenêtre s'ouvre ; tout ce qui arrive pendant [window] part ensemble. */
    private suspend fun enqueue(
        actions: List<SignalAction>,
        sheets: Set<String>?,
    ) {
        lock.withLock {
            pendingActions += actions
            if (SignalAction.ReloadSharing in actions) pendingSheets += sheets.orEmpty()
            if (flushJob?.isActive == true) return
            flushJob =
                scope.launch {
                    delay(window)
                    flush()
                }
        }
    }

    private suspend fun flush() {
        val (actions, sheets) =
            lock.withLock {
                val batch = pendingActions.toSet() to pendingSheets.toSet()
                pendingActions.clear()
                pendingSheets.clear()
                flushJob = null
                batch
            }
        if (SignalAction.Pull in actions) requestPull()
        if (SignalAction.ReloadInvitations in actions) invitations.tryEmit(Unit)
        if (SignalAction.ReloadSharing in actions && sheets.isNotEmpty()) sharing.tryEmit(sheets)
    }

    companion object {
        private const val TAG = "RealtimeSignals"
        private const val BUFFER = 8
        private const val ITEMS = "items"

        /** Regroupement des signaux (#87 §6.2). */
        val WINDOW: Duration = 300.milliseconds

        val RETRY_DELAY: Duration = 10.seconds

        /**
         * Seconde descente après chaque jonction, même valeur qu'iOS (`RealtimeSignals.subscribedFollowUpDelay`) : la
         * parade au signal perdu sur un Realtime froid (`docs/data-model.md`, « Limite : signal perdu juste après
         * l'abonnement »).
         */
        val SUBSCRIBED_FOLLOW_UP_DELAY: Duration = 2_500.milliseconds
    }
}
