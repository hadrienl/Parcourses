package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Pourquoi une suppression n'est pas allée au bout. Mêmes noms qu'iOS. */
enum class AccountDeletionError {
    /** Pas de réseau au moment de la demande : rien n'a été touché. */
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
    /** Compte supprimé, appareil purgé, nouveau compte anonyme vide. */
    data object Deleted : AccountDeletionOutcome

    /** « Annuler » : le compte existe toujours, la synchronisation a repris. */
    data object Cancelled : AccountDeletionOutcome

    data class Failed(
        val error: AccountDeletionError,
    ) : AccountDeletionOutcome
}

/** Ce que l'app fait autour de la suppression, hors de la base et du serveur. Chaque étape est rejouable. */
interface AccountDeletionHost {
    /** Étape 1 : travaux WorkManager annulés, moteur arrêté une fois sa passe en cours finie. */
    suspend fun suspendSync()

    /** Étape 2 : Live Update retirée et ses préférences effacées, mode courses fermé **sans** `closeVisit`. */
    suspend fun endShopping()

    /** Refus, ou « Annuler » : la synchronisation reprend comme avant. */
    fun resumeSync()

    /** Étape 5, drapeau effacé : état de l'app recréé, navigation sur les listes, synchronisation replanifiée. */
    suspend fun rebuild()
}

/**
 * « Supprimer mes données » (#68 §5.3), même déroulé qu'iOS :
 * 1. drapeau `account.deletion` écrit, synchronisation arrêtée ([AccountDeletionHost.suspendSync]) ;
 * 2. Live Update et mode courses fermés ([AccountDeletionHost.endShopping]) ;
 * 3. suppression sur le serveur ([RemoteGateway.deleteAccount], [timeout]) ; en cas de doute,
 *    [RemoteGateway.verifySession] dit si le compte existe encore ;
 * 4. purge de l'appareil ([LocalDataPurge]), puis [RemoteGateway.signOutLocally] ;
 * 5. drapeau effacé **en dernier**, puis `ensureSession` : marqueurs vides, le nouveau compte est adopté sans
 *    reprise de compte, donc sans renvoi des données effacées.
 *
 * Tant que le drapeau existe, ni synchronisation ni création de compte ([DeletionGuardedGateway],
 * `SyncDependencies.isAccountDeletionPending`). Le processus peut mourir à toute étape : [resumePending] reprend au
 * lancement, en « vérification ». Sans [gateway] (build sans Supabase), seul l'appareil est purgé (§5.7).
 */
class AccountDeletion(
    private val gateway: RemoteGateway?,
    private val flag: AccountDeletionFlag,
    private val purge: LocalDataPurge,
    private val host: AccountDeletionHost,
    private val isOnline: () -> Boolean,
    private val timeout: Duration = 15.seconds,
) {
    /** Une seule suppression à la fois : un double appui, ou la reprise au lancement pendant une demande. */
    private val lock = Mutex()

    /** Une suppression a commencé et n'est pas finie (drapeau présent). */
    val isPending: Boolean get() = flag.isPending

    /** Nouvelle demande (après confirmation), ou « Réessayer » si une suppression est déjà en cours. */
    suspend fun run(): AccountDeletionOutcome =
        lock.withLock {
            if (!flag.isPending) {
                // Le réseau est exigé (D1) : vérifié avant de toucher à quoi que ce soit.
                if (gateway != null && !isOnline()) {
                    return@withLock AccountDeletionOutcome.Failed(AccountDeletionError.Offline)
                }
                flag.write(AccountDeletionMarker(AccountDeletionPhase.Requested, sessionAccount()))
            }
            proceed()
        }

    /** Au lancement : reprend une suppression interrompue par la mort du processus. `null` s'il n'y en a pas. */
    suspend fun resumePending(): AccountDeletionOutcome? = if (flag.isPending) run() else null

    /**
     * « Annuler », proposé quand la suppression n'est pas confirmée. Le compte est d'abord vérifié : s'il n'existe
     * plus, rendre la synchronisation renverrait tout vers un nouveau compte, donc la purge se termine ; si on ne peut
     * pas le savoir (réseau), rien ne change.
     */
    @Suppress("TooGenericExceptionCaught") // Une panne locale garde le drapeau : jamais de reprise à moitié.
    suspend fun cancel(): AccountDeletionOutcome =
        lock.withLock {
            val marker = flag.read() ?: return@withLock AccountDeletionOutcome.Cancelled
            try {
                val state =
                    when {
                        marker.phase == AccountDeletionPhase.ServerDeleted -> ServerState.Gone
                        gateway == null -> ServerState.Exists
                        else -> verify(gateway)
                    }
                when (state) {
                    ServerState.Gone -> {
                        flag.write(marker.copy(phase = AccountDeletionPhase.ServerDeleted))
                        finish()
                    }

                    ServerState.Exists -> {
                        flag.clear()
                        host.resumeSync()
                        AccountDeletionOutcome.Cancelled
                    }

                    ServerState.Refused, ServerState.Unreachable -> {
                        AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Annulation interrompue : ${e.javaClass.simpleName}")
                AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
            }
        }

    @Suppress("TooGenericExceptionCaught", "ReturnCount") // Toute panne locale garde le drapeau ; gardes d'étapes.
    private suspend fun proceed(): AccountDeletionOutcome {
        try {
            host.suspendSync()
            host.endShopping()
            val marker = flag.read() ?: return AccountDeletionOutcome.Cancelled
            if (gateway != null && marker.phase == AccountDeletionPhase.Requested) {
                when (deleteOnServer(gateway)) {
                    ServerState.Gone -> {
                        flag.write(marker.copy(phase = AccountDeletionPhase.ServerDeleted))
                    }

                    ServerState.Refused -> {
                        flag.clear()
                        host.resumeSync()
                        return AccountDeletionOutcome.Failed(AccountDeletionError.Refused)
                    }

                    ServerState.Exists, ServerState.Unreachable -> {
                        return AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
                    }
                }
            }
            return finish()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Base ou stockage indisponibles : le drapeau reste, la suppression reprendra (« Réessayer », lancement).
            Log.w(TAG, "Suppression interrompue : ${e.javaClass.simpleName}")
            return AccountDeletionOutcome.Failed(AccountDeletionError.Unknown)
        }
    }

    /** Étapes 4 et 5. Rejouable : une base vide et une session absente le restent. */
    private suspend fun finish(): AccountDeletionOutcome {
        purge.run()
        gateway?.signOutLocally()
        flag.clear()
        gateway?.let { signIn(it) }
        host.rebuild()
        Log.i(TAG, "Données supprimées")
        return AccountDeletionOutcome.Deleted
    }

    private enum class ServerState { Gone, Exists, Refused, Unreachable }

    @Suppress("ReturnCount") // Succès, délai, erreur : trois issues.
    private suspend fun deleteOnServer(remote: RemoteGateway): ServerState {
        val error =
            try {
                withTimeoutOrNull(timeout) { remote.deleteAccount() } ?: return verify(remote)
                return ServerState.Gone
            } catch (e: RemoteError) {
                e
            }
        Log.i(TAG, "Suppression non confirmée : ${error.message}")
        return if (isDefinitive(error)) ServerState.Refused else verify(remote)
    }

    /**
     * Refus définitif : rien n'est parti, ou le serveur a rejeté la requête (4xx autre qu'une session absente ou un
     * refus passager). Le reste (réseau, 5xx, `55P03`, `57014`, session absente…) est un doute.
     */
    private fun isDefinitive(error: RemoteError): Boolean =
        when (error) {
            is RemoteError.Rejected, is RemoteError.Constraint, is RemoteError.DependencyMissing -> true

            // Stockage de session illisible : la requête n'est jamais partie.
            is RemoteError.SecureStorageLocked -> true

            is RemoteError.Server -> error.isCappedClientFailure

            else -> false
        }

    /** Lève le doute : « introuvable » ou session disparue, c'est que la suppression a eu lieu. */
    private suspend fun verify(remote: RemoteGateway): ServerState =
        try {
            withTimeoutOrNull(timeout) { remote.verifySession() }?.let { ServerState.Exists } ?: ServerState.Unreachable
        } catch (_: RemoteError.Unauthorized) {
            ServerState.Gone
        } catch (_: RemoteError.AccountChanged) {
            // La session vaut, pour un autre compte que le dernier connu : il existe.
            ServerState.Exists
        } catch (e: RemoteError) {
            Log.i(TAG, "Vérification impossible : ${e.message}")
            ServerState.Unreachable
        }

    /** Compte visé, pour le drapeau. `null` sans session (rien à supprimer sur le serveur). */
    private suspend fun sessionAccount(): String? =
        try {
            gateway?.let { withTimeoutOrNull(timeout) { it.sessionAccountId() } }?.toString()
        } catch (_: RemoteError) {
            null
        }

    /** Nouveau compte anonyme. Un échec n'empêche rien : la synchronisation le créera plus tard. */
    private suspend fun signIn(remote: RemoteGateway) {
        try {
            withTimeoutOrNull(timeout) { remote.ensureSession() }
        } catch (e: RemoteError) {
            Log.i(TAG, "Nouveau compte reporté : ${e.message}")
        }
    }

    private companion object {
        const val TAG = "AccountDeletion"
    }
}
