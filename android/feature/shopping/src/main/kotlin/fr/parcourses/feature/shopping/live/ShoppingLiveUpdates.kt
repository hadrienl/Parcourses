package fr.parcourses.feature.shopping.live

import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.RepositoryException
import fr.parcourses.core.data.repository.VisitRepository
import fr.parcourses.core.data.sync.IdentifierRemap
import fr.parcourses.feature.shopping.ShoppingTimings
import fr.parcourses.feature.shopping.checkSubject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant

/** Ce que le mode courses envoie à la Live Update. */
interface LiveUpdateSink {
    /** État courant de l'écran (sans effet s'il n'a pas changé). */
    fun publish(state: ShoppingLiveState)

    /** Visite terminée, expirée ou abandonnée : la notification disparaît. */
    fun end(visitId: String)
}

/** L'`Application` porte le contrôleur unique : le receiver et l'écran le retrouvent par elle. */
interface LiveUpdateHost {
    val liveUpdates: ShoppingLiveUpdates
}

/**
 * Pilote de la Live Update (#10 §9), pendant d'`ActivityKitShoppingActivity` d'iOS. **Une seule instance par
 * processus** (`AppContainer`) : toutes les demandes (écran, receiver, reprise de compte, lancement) passent par une
 * file traitée dans l'ordre, puis l'affichage suit, au plus une fois toutes les [minInterval] (le système écarte les
 * mises à jour trop rapprochées).
 *
 * Règles, vérifiées à chaque affichage contre la base, quelle que soit l'origine de la demande :
 * - la notification ne suit que la visite **ouverte** : une visite close, supprimée ou d'une autre liste la retire, et
 *   l'état d'une autre visite n'est jamais montré ;
 * - **périmée** à 45 min sans coche (`setTimeoutAfter` sur la dernière coche) : le système la retire même si l'app
 *   ne tourne plus, et elle n'est plus reposée ensuite ;
 * - le prochain article n'est jamais un article déjà coché ailleurs (état confronté à la base) ;
 * - une notification écartée par la personne ne revient pas pour cette visite ;
 * - sans autorisation, rien n'est affiché et le mode courses n'en dépend jamais.
 *
 * Aucun échec n'est avalé : tout est journalisé ([log]).
 */
@Suppress("LongParameterList", "TooManyFunctions") // Les dépendances du receiver comme de l'écran, et rien d'autre.
class ShoppingLiveUpdates(
    private val notifier: LiveUpdateNotifier,
    private val visits: VisitRepository,
    private val lists: ListRepository,
    private val analyzer: EntryAnalyzer,
    private val preferences: LiveUpdatePreferences,
    scope: CoroutineScope,
    remaps: Flow<IdentifierRemap> = emptyFlow(),
    private val timings: ShoppingTimings = ShoppingTimings(),
    private val now: () -> Instant = { Clock.System.now() },
    private val minInterval: Duration = 300.milliseconds,
    private val log: LiveUpdateLog = AndroidLiveUpdateLog,
) : LiveUpdateSink {
    private sealed interface Command {
        data class Publish(
            val state: ShoppingLiveState,
        ) : Command

        data class End(
            val visitId: String,
        ) : Command

        data class CheckNext(
            val visitId: String,
            val itemId: String,
        ) : Command

        data class Dismissed(
            val visitId: String,
        ) : Command

        data class Remap(
            val remap: IdentifierRemap,
        ) : Command

        /** Lancement : une notification qui ne suit pas la visite ouverte est retirée. */
        data object Reconcile : Command

        /** Autorisation accordée : l'état courant est reposé. */
        data object Refresh : Command

        /** Suppression des données (#68) : plus rien d'affiché ni de retenu. */
        data object EndAll : Command
    }

    private class Request(
        val command: Command,
        val done: CompletableDeferred<Unit>?,
    )

    private val commands = Channel<Request>(Channel.UNLIMITED)

    /** État voulu ; `null` : rien à afficher. Lu et écrit par la seule boucle [run]. */
    private var current: ShoppingLiveState? = null

    /** Dernier affichage et dernière activité de sa visite (qui fixe l'expiration) : rien ne repart sans changement. */
    private var posted: Pair<ShoppingLiveState, Instant>? = null
    private var lastPostAt: Instant? = null
    private var blockedLogged = false

    init {
        scope.launch { run() }
        scope.launch { remaps.collect { if (it.identifiers.isNotEmpty()) send(Command.Remap(it)) } }
    }

    override fun publish(state: ShoppingLiveState) = send(Command.Publish(state))

    override fun end(visitId: String) = send(Command.End(visitId))

    /** La personne a écarté la notification (`deleteIntent`). Terminé quand c'est retenu. */
    fun dismissed(visitId: String): Deferred<Unit> = request(Command.Dismissed(visitId))

    fun refresh() = send(Command.Refresh)

    /** Au lancement, et après la reprise d'une visite : retire toute notification sans visite ouverte. */
    fun reconcile(): Deferred<Unit> = request(Command.Reconcile)

    /**
     * « Supprimer mes données » (#68) : la notification `10_010` est retirée et les préférences (`live_updates`)
     * effacées, l'état en mémoire oublié. Terminé quand c'est fait. Équivalent de `ShoppingActivity.endAll` d'iOS.
     */
    fun endAll(): Deferred<Unit> = request(Command.EndAll)

    /**
     * Action « Cocher le suivant » : coche [itemId], l'article que la notification affichait, par la même règle que
     * l'écran (`VisitRepository.checkItem` refuse un article déjà coché : double appui, ou écran ouvert en même
     * temps). L'écran ouvert l'apprend par son observation de la base.
     */
    fun checkNext(
        visitId: String,
        itemId: String,
    ): Deferred<Unit> = request(Command.CheckNext(visitId, itemId))

    private fun send(command: Command) {
        commands.trySend(Request(command, null))
    }

    private fun request(command: Command): Deferred<Unit> {
        val done = CompletableDeferred<Unit>()
        commands.trySend(Request(command, done))
        return done
    }

    // region Boucle

    private suspend fun run() {
        while (true) {
            val waiting = mutableListOf<CompletableDeferred<Unit>>()
            handle(commands.receive(), waiting)
            drain(waiting)
            val wait = lastPostAt?.let { it + minInterval - now() } ?: ZERO
            if (wait > ZERO) {
                delay(wait)
                drain(waiting)
            }
            guarded("affichage") { render() }
            waiting.forEach { it.complete(Unit) }
        }
    }

    private suspend fun drain(waiting: MutableList<CompletableDeferred<Unit>>) {
        while (true) handle(commands.tryReceive().getOrNull() ?: return, waiting)
    }

    private suspend fun handle(
        request: Request,
        waiting: MutableList<CompletableDeferred<Unit>>,
    ) {
        request.done?.let(waiting::add)
        guarded(request.command.javaClass.simpleName) { apply(request.command) }
    }

    @Suppress("TooGenericExceptionCaught") // La boucle ne doit jamais s'arrêter ; l'échec est journalisé.
    private suspend fun guarded(
        what: String,
        work: suspend () -> Unit,
    ) {
        try {
            work()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.error("Live Update : échec ($what)", e)
        }
    }

    // endregion

    // region Commandes

    private suspend fun apply(command: Command) {
        when (command) {
            is Command.Publish -> {
                accept(command.state)
            }

            is Command.End -> {
                val shown = restored()
                if (shown == null || shown.visitId == command.visitId) current = null
            }

            is Command.CheckNext -> {
                checkNext(command)
            }

            is Command.Dismissed -> {
                preferences.dismissedVisitId = command.visitId
                posted = null
            }

            is Command.Remap -> {
                // Processus relancé : l'état est celui de la notification affichée, à renommer aussi.
                current = restored()?.remapped(command.remap)
                preferences.dismissedVisitId?.let { preferences.dismissedVisitId = command.remap[it] }
                // Les actions portent les anciens identifiants : la notification est reposée.
                posted = null
            }

            Command.Reconcile -> {
                restored()
            }

            Command.Refresh -> {
                posted = null
                blockedLogged = false
                restored()
            }

            Command.EndAll -> {
                current = null
                posted = null
                lastPostAt = null
                notifier.cancel()
                preferences.clear()
            }
        }
    }

    /** L'écran d'une autre visite ne remplace la notification que si cette visite est bien ouverte. */
    private suspend fun accept(state: ShoppingLiveState) {
        val shown = restored()
        if (shown != null && shown.visitId != state.visitId && !isOpen(state.visitId)) {
            log.info("Live Update : état d'une visite close ignoré")
            return
        }
        current = state
    }

    private suspend fun checkNext(command: Command.CheckNext) {
        val state = restored()
        if (state == null || state.visitId != command.visitId) {
            log.warn("« Cocher le suivant » ignoré : la notification ne suit plus cette visite")
            return
        }
        val item = lists.items(state.listId).firstOrNull { it.id == command.itemId }
        // Seul un article que la notification montre encore à prendre se coche : ni un article retiré ou passé
        // introuvable entre-temps, ni un article d'un ancien état.
        if (item == null || item.notFoundAt != null || state.pending.none { it.id == command.itemId }) {
            log.warn("« Cocher le suivant » ignoré : article plus à prendre")
            return
        }
        try {
            visits.checkItem(
                visitId = command.visitId,
                itemId = command.itemId,
                subject = checkSubject(item, analyzer),
                checkedAt = now(),
                // Même retenue que l'écran : rien ne part au serveur avant la fin du délai d'annulation.
                sendAfter = timings.undo + timings.sendMargin,
            )
        } catch (expected: RepositoryException.AlreadyChecked) {
            log.info("« Cocher le suivant » : article déjà coché (écran ou double appui)")
        } catch (e: RepositoryException) {
            log.warn("« Cocher le suivant » refusé", e)
        }
    }

    /** État courant, sinon celui de la notification affichée (processus relancé). Une notification illisible part. */
    private fun restored(): ShoppingLiveState? {
        current?.let { return it }
        return when (val active = notifier.active()) {
            LiveUpdateNotifier.Active.None -> {
                null
            }

            LiveUpdateNotifier.Active.Unreadable -> {
                log.info("Live Update illisible retirée")
                notifier.cancel()
                null
            }

            is LiveUpdateNotifier.Active.Shown -> {
                active.state.also { current = it }
            }
        }
    }

    private suspend fun isOpen(visitId: String): Boolean = visits.visit(visitId)?.let { it.endedAt == null } == true

    // endregion

    // region Affichage

    private suspend fun render() {
        val state = current
        val last = state?.let { lastActivityIfLive(it) }
        if (state == null || last == null) return hide()
        val left = timings.expiry - (now() - last)
        val fresh = state.reconciled(lists.items(state.listId))
        current = fresh
        when {
            // Écartée par la personne : rien ne revient pour cette visite (l'état reste, pour le lien et l'action).
            preferences.dismissedVisitId == fresh.visitId -> {
                posted = null
            }

            fresh.total == 0 -> {
                notifier.cancel()
                posted = null
            }

            !notifier.canPost() -> {
                if (!blockedLogged) log.info("Live Update en attente : notifications non autorisées")
                blockedLogged = true
            }

            posted != fresh to last -> {
                blockedLogged = false
                if (notifier.post(fresh, left)) {
                    posted = fresh to last
                    lastPostAt = now()
                } else {
                    log.warn("Live Update refusée par le système")
                }
            }
        }
    }

    /**
     * Dernière activité de la visite suivie, `null` si elle ne doit plus être montrée (close, disparue, périmée, ou
     * liste supprimée).
     */
    private suspend fun lastActivityIfLive(state: ShoppingLiveState): Instant? {
        val visit = visits.visit(state.visitId)?.takeIf { lists.list(state.listId) != null }
        val last = visit?.let { visits.lastActivity(it.id) ?: it.startedAt }
        when {
            visit == null || visit.endedAt != null -> log.info("Live Update retirée : visite close ou sans liste")
            last == null || now() - last >= timings.expiry -> log.info("Live Update retirée : visite périmée (45 min)")
            else -> return last
        }
        return null
    }

    /** Rien à suivre : la notification part, si elle est affichée (sans appel au système à chaque commande). */
    private fun hide() {
        current = null
        if (posted != null || notifier.active() != LiveUpdateNotifier.Active.None) notifier.cancel()
        posted = null
    }

    // endregion
}
