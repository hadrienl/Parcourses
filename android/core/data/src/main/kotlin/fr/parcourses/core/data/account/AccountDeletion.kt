package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** Pourquoi une suppression n'est pas allée au bout. Mêmes noms qu'iOS. */
enum class AccountDeletionError {
    /** La requête n'est jamais partie (pas de réseau, hôte introuvable) : rien n'a été touché. */
    Offline,

    /** Le serveur a refusé pour de bon : rien n'a été effacé, la synchronisation a repris. */
    Refused,

    /**
     * Le serveur n'a pas confirmé, ou l'appareil n'a pas fini sa purge : le drapeau reste, la synchronisation reste
     * arrêtée. « Réessayer » ([AccountDeletion.run]) ou « Annuler » ([AccountDeletion.cancel]).
     */
    Unknown,
}

sealed interface AccountDeletionOutcome {
    /** Compte supprimé (ou build sans serveur), appareil purgé, nouveau compte anonyme vide. */
    data object Deleted : AccountDeletionOutcome

    /**
     * Reprise sans session locale (ou avec la session d'un autre compte) : l'appareil est purgé, mais le serveur n'a
     * pas pu être atteint ; ses données partiront avec la purge des comptes inactifs (365 jours).
     */
    data object DeletedLocally : AccountDeletionOutcome

    /** « Annuler » : le compte existe toujours, ou rien ne prouve le contraire ; la synchronisation a repris. */
    data object Cancelled : AccountDeletionOutcome

    /** [retrySoon] : « Annuler » trop tôt après la dernière tentative, « Réessayez dans un instant. ». */
    data class Failed(
        val error: AccountDeletionError,
        val retrySoon: Boolean = false,
    ) : AccountDeletionOutcome
}

/** Ce que l'app fait autour de la suppression, hors de la base et du serveur. Chaque étape est rejouable. */
interface AccountDeletionHost {
    /** Étape 1 : travaux WorkManager annulés, moteur arrêté une fois sa passe en cours finie. */
    suspend fun suspendSync()

    /** Étape 2 : Live Update retirée et arrêtée, mode courses fermé **sans** `closeVisit`. Préférences gardées. */
    suspend fun endShopping()

    /**
     * Étape 4, base vidée : notification retirée encore une fois et préférences de la Live Update effacées. Un échec
     * lève : le drapeau reste.
     */
    suspend fun clearLocalState()

    /** Refus, ou « Annuler » : la Live Update et la synchronisation reprennent comme avant. */
    fun resumeSync()

    /** Étape 5, drapeau effacé : état de l'app recréé, navigation sur les listes, synchronisation replanifiée. */
    suspend fun rebuild()
}

/** Délais de la suppression. */
data class AccountDeletionTiming(
    /** Limite de chaque appel au serveur (RPC, vérification, nouveau compte). */
    val timeout: Duration = 15.seconds,
    /** « Annuler » n'est cru qu'après ce délai depuis la dernière tentative : une RPC lente peut encore aboutir. */
    val cancelAfter: Duration = 30.seconds,
    val now: () -> Instant = { Clock.System.now() },
)

/**
 * « Supprimer mes données » (#68 §5.3), même déroulé et mêmes règles qu'iOS :
 * 1. drapeau `account.deletion` écrit tout de suite, puis complété du compte de la session ; synchronisation arrêtée ;
 * 2. Live Update et mode courses fermés ([AccountDeletionHost.endShopping]) ;
 * 3. suppression sur le serveur ([RemoteGateway.deleteAccount]), l'heure de la tentative écrite **avant** l'envoi ;
 * 4. purge de l'appareil ([LocalDataPurge], [AccountDeletionHost.clearLocalState]), puis
 *    [RemoteGateway.signOutLocally] ;
 * 5. drapeau effacé **en dernier**, puis `ensureSession` : marqueurs vides, le nouveau compte est adopté sans
 *    reprise de compte, donc sans renvoi des données effacées.
 *
 * Seuls les codes GoTrue de [DELETION_PROOFS] prouvent que le compte n'existe plus. Un refus ou une requête jamais
 * partie n'effacent le drapeau qu'à la **première** tentative ; ensuite, il faut que la vérification trouve le
 * compte. Tout le reste est un doute : le drapeau reste.
 *
 * Tant que le drapeau existe, ni synchronisation ni création de compte ([DeletionGuardedGateway],
 * `SyncDependencies.isAccountDeletionPending`). Le processus peut mourir à toute étape : [resumePending] reprend au
 * lancement. Sans [gateway] (build sans Supabase), seul l'appareil est purgé (§5.7).
 */
@Suppress("TooManyFunctions")
class AccountDeletion(
    private val gateway: RemoteGateway?,
    private val flag: AccountDeletionFlag,
    private val purge: LocalDataPurge,
    private val host: AccountDeletionHost,
    private val isOnline: () -> Boolean,
    private val timing: AccountDeletionTiming = AccountDeletionTiming(),
) {
    /** Une seule suppression à la fois : un double appui, ou la reprise au lancement pendant une demande. */
    private val lock = Mutex()

    /** Une suppression a commencé et n'est pas finie (drapeau présent). Lit le disque : hors du fil principal. */
    val isPending: Boolean get() = flag.isPending

    /** Nouvelle demande (après confirmation), ou « Réessayer » si une suppression est déjà en cours. */
    suspend fun run(): AccountDeletionOutcome =
        lock.withLock {
            if (flag.read() == null) {
                // Le réseau est exigé (D1) : vérifié avant de toucher à quoi que ce soit.
                if (gateway != null && !isOnline()) {
                    return@withLock AccountDeletionOutcome.Failed(AccountDeletionError.Offline)
                }
                // Le drapeau d'abord (C7) : aucun compte ne doit pouvoir naître pendant qu'on lit la session.
                flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, null))
                sessionAccount()?.let { id -> flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, id)) }
            }
            proceed()
        }

    /** Au lancement : reprend une suppression interrompue par la mort du processus. `null` s'il n'y en a pas. */
    suspend fun resumePending(): AccountDeletionOutcome? =
        lock.withLock { if (flag.read() == null) null else proceed() }

    /**
     * « Annuler », proposé quand la suppression n'est pas confirmée (C2). Le drapeau n'est effacé que si la dernière
     * tentative date d'au moins [AccountDeletionTiming.cancelAfter] et qu'une vérification trouve encore le compte,
     * ou s'il n'y a plus de session locale (aucune preuve possible : la personne garde ses données). Une preuve de
     * suppression termine la purge.
     */
    @Suppress("TooGenericExceptionCaught") // Une panne locale garde le drapeau : jamais de reprise à moitié.
    suspend fun cancel(): AccountDeletionOutcome =
        lock.withLock {
            val marker = flag.read() ?: return@withLock AccountDeletionOutcome.Cancelled
            try {
                cancelPending(marker)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Annulation interrompue : ${e.javaClass.simpleName}")
                AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
            }
        }

    @Suppress("ReturnCount") // Une garde par règle de C2.
    private suspend fun cancelPending(marker: AccountDeletionMarker): AccountDeletionOutcome {
        // Build sans serveur : « Annuler » ne relance pas la purge, l'appareil garde ce qui reste.
        val remote = gateway ?: return abandon(AccountDeletionOutcome.Cancelled)
        if (marker.phase == AccountDeletionPhase.ServerDeleted) return finish(AccountDeletionOutcome.Deleted)
        val last = marker.lastAttemptAt
        if (last != null && timing.now() - last < timing.cancelAfter) {
            return AccountDeletionOutcome.Failed(AccountDeletionError.Unknown, retrySoon = true)
        }
        return when (verify(remote, marker)) {
            ServerState.Gone -> {
                deleted()
            }

            ServerState.Exists, ServerState.NoSession -> {
                abandon(AccountDeletionOutcome.Cancelled)
            }

            ServerState.Refused, ServerState.NotSent, ServerState.Unreachable -> {
                AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
            }
        }
    }

    @Suppress("TooGenericExceptionCaught", "ReturnCount") // Toute panne locale garde le drapeau ; gardes d'étapes.
    private suspend fun proceed(): AccountDeletionOutcome {
        try {
            host.suspendSync()
            host.endShopping()
            val marker = flag.read() ?: return AccountDeletionOutcome.Cancelled
            val remote = gateway
            if (remote == null || marker.phase == AccountDeletionPhase.ServerDeleted) {
                return finish(AccountDeletionOutcome.Deleted)
            }
            return when (deleteOnServer(remote, marker)) {
                ServerState.Gone -> {
                    deleted()
                }

                // Pas de session pour atteindre le serveur : l'appareil seul (C3).
                ServerState.NoSession -> {
                    finish(AccountDeletionOutcome.DeletedLocally)
                }

                ServerState.Refused -> {
                    abandon(AccountDeletionOutcome.Failed(AccountDeletionError.Refused))
                }

                ServerState.NotSent -> {
                    abandon(AccountDeletionOutcome.Failed(AccountDeletionError.Offline))
                }

                ServerState.Exists, ServerState.Unreachable -> {
                    AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Base ou stockage indisponibles : le drapeau reste, la suppression reprendra (« Réessayer », lancement).
            Log.w(TAG, "Suppression interrompue : ${e.javaClass.simpleName}")
            return AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
        }
    }

    /** Le serveur a supprimé : l'étape est retenue, puis l'appareil est purgé. */
    private suspend fun deleted(): AccountDeletionOutcome {
        flag.read()?.let { flag.write(it.copy(phase = AccountDeletionPhase.ServerDeleted)) }
        return finish(AccountDeletionOutcome.Deleted)
    }

    /** Rien n'a été effacé : le drapeau part et tout reprend. */
    private fun abandon(outcome: AccountDeletionOutcome): AccountDeletionOutcome {
        flag.clear()
        host.resumeSync()
        return outcome
    }

    /** Étapes 4 et 5. Rejouable : une base vide et une session absente le restent. */
    private suspend fun finish(outcome: AccountDeletionOutcome): AccountDeletionOutcome {
        purge.run()
        host.clearLocalState()
        gateway?.signOutLocally()
        flag.clear()
        gateway?.let { signIn(it) }
        host.rebuild()
        Log.i(TAG, "Données supprimées")
        return outcome
    }

    private enum class ServerState { Gone, Exists, NoSession, Refused, NotSent, Unreachable }

    @Suppress("ReturnCount") // Session, envoi, classement : une issue par cas.
    private suspend fun deleteOnServer(
        remote: RemoteGateway,
        marker: AccountDeletionMarker,
    ): ServerState {
        when (localSession(remote, marker)) {
            LocalSession.None -> return ServerState.NoSession

            LocalSession.Gone -> return ServerState.Gone

            // Session présente, ou illisible pour l'instant : la RPC dira le reste.
            LocalSession.Present, LocalSession.Unknown -> Unit
        }
        val current = flag.read() ?: marker
        val first = current.lastAttemptAt == null
        // Avant l'envoi : si la réponse se perd ou que le processus meurt, on saura qu'une tentative a eu lieu.
        flag.write(current.copy(lastAttemptAt = timing.now()))
        val error =
            try {
                withTimeoutOrNull(timing.timeout) { remote.deleteAccount() } ?: return verify(remote, current)
                return ServerState.Gone
            } catch (e: RemoteError) {
                e
            }
        Log.i(TAG, "Suppression non confirmée : ${error.message}")
        val refusal =
            when {
                error is RemoteError.Network && error.notSent -> ServerState.NotSent
                isDefinitive(error) -> ServerState.Refused
                else -> return verify(remote, current)
            }
        if (first) return refusal
        // Une tentative précédente a pu supprimer le compte : le refus n'est cru que si le compte existe encore.
        return when (val state = verify(remote, current)) {
            ServerState.Exists -> refusal
            else -> state
        }
    }

    /**
     * Refus définitif : le serveur a rejeté la requête (4xx autre qu'une session absente ou un refus passager). Le
     * reste (réseau, délai, 5xx, `55P03`, `57014`, `42501`, session, stockage illisible) est un doute.
     */
    private fun isDefinitive(error: RemoteError): Boolean =
        when (error) {
            is RemoteError.Rejected, is RemoteError.Constraint, is RemoteError.DependencyMissing -> true
            is RemoteError.Server -> error.isCappedClientFailure
            else -> false
        }

    private enum class LocalSession { Present, None, Gone, Unknown }

    /**
     * Session de l'appareil, comparée au compte du drapeau (C7) : celle d'un autre compte ne peut pas supprimer le
     * bon, elle compte comme absente. Un drapeau sans compte adopte celui de la session.
     */
    @Suppress("ReturnCount") // Une issue par cas.
    private suspend fun localSession(
        remote: RemoteGateway,
        marker: AccountDeletionMarker,
    ): LocalSession {
        val id =
            try {
                withTimeoutOrNull(timing.timeout) { remote.sessionAccountId() }?.toString()
                    ?: return LocalSession.Unknown
            } catch (e: RemoteError.Unauthorized) {
                return when {
                    e.authCode in DELETION_PROOFS -> LocalSession.Gone
                    e.noLocalSession -> LocalSession.None
                    else -> LocalSession.Unknown
                }
            } catch (_: RemoteError) {
                return LocalSession.Unknown
            }
        val expected = marker.accountId
        if (expected != null && expected != id) return LocalSession.None
        if (expected == null) flag.read()?.let { flag.write(it.copy(accountId = id)) }
        return LocalSession.Present
    }

    /**
     * Lève le doute (C1) : rafraîchissement forcé puis `getUser`. Seuls les codes de [DELETION_PROOFS] prouvent la
     * suppression ; tout autre refus (`bad_jwt`…) ou erreur locale reste un doute.
     */
    @Suppress("ReturnCount") // Session locale d'abord, puis le serveur.
    private suspend fun verify(
        remote: RemoteGateway,
        marker: AccountDeletionMarker,
    ): ServerState {
        when (localSession(remote, marker)) {
            LocalSession.None -> return ServerState.NoSession
            LocalSession.Gone -> return ServerState.Gone
            LocalSession.Unknown -> return ServerState.Unreachable
            LocalSession.Present -> Unit
        }
        return try {
            withTimeoutOrNull(timing.timeout) { remote.verifySession(refresh = true) }
                ?.let { ServerState.Exists }
                ?: ServerState.Unreachable
        } catch (e: RemoteError.Unauthorized) {
            when {
                e.authCode in DELETION_PROOFS -> ServerState.Gone
                e.noLocalSession -> ServerState.NoSession
                else -> ServerState.Unreachable
            }
        } catch (e: RemoteError) {
            Log.i(TAG, "Vérification impossible : ${e.message}")
            ServerState.Unreachable
        }
    }

    /** Compte visé, pour le drapeau. `null` sans session lisible. */
    private suspend fun sessionAccount(): String? =
        try {
            gateway?.let { withTimeoutOrNull(timing.timeout) { it.sessionAccountId() } }?.toString()
        } catch (_: RemoteError) {
            null
        }

    /** Nouveau compte anonyme. Un échec n'empêche rien : la synchronisation le créera plus tard. */
    private suspend fun signIn(remote: RemoteGateway) {
        try {
            withTimeoutOrNull(timing.timeout) { remote.ensureSession() }
        } catch (e: RemoteError) {
            Log.i(TAG, "Nouveau compte reporté : ${e.message}")
        }
    }

    companion object {
        private const val TAG = "AccountDeletion"

        /** Codes GoTrue qui prouvent que le compte n'existe plus (contrat 68.1, règle commune C1). */
        val DELETION_PROOFS = setOf("user_not_found", "refresh_token_not_found", "session_not_found")
    }
}
