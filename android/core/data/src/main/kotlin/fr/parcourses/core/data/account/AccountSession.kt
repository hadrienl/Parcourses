package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/** Compte de l'appareil, pour les écrans (À propos, Listes). */
data class AccountState(
    val kind: AccountKind = AccountKind.Anonymous,
    /** Adresse du compte e-mail, lue dans la session ; `null` tant qu'elle n'est pas connue. */
    val email: String? = null,
    val displayName: String? = null,
    /** Compte e-mail sans session valable : « Reconnectez-vous pour synchroniser » (vecteur `009`). */
    val needsSignIn: Boolean = false,
)

/**
 * État du compte pour les écrans (#87 §2.4), mêmes noms qu'iOS : type de compte (drapeau `account.kind`), adresse,
 * prénom, et session perdue d'un compte e-mail. [waitsForSession] : `SyncEngine.waitsForSession` du moteur courant.
 *
 * Purges en échec (#129), mêmes noms qu'iOS : [purgeFailureCount], [lastPurgeFailure], [purgeFailureThreshold]. Le
 * compteur ([PurgeFailureCounter]) est en mémoire seulement : il repart de 0 à chaque lancement.
 */
class AccountSession(
    private val gateway: RemoteGateway?,
    private val kind: AccountKindFlag,
    waitsForSession: Flow<Boolean> = flowOf(false),
    private val purgeFailures: PurgeFailureCounter = PurgeFailureCounter(),
) : PurgeFailureRecorder by purgeFailures {
    private val profile = MutableStateFlow(Profile())

    /** Purges en échec depuis la dernière réussie. Jamais écrit sur le disque. */
    val purgeFailureCount: StateFlow<Int> get() = purgeFailures.count

    /** Dernière purge en échec : son code va dans l'objet du message de « Nous écrire ». */
    val lastPurgeFailure: StateFlow<PurgeFailure?> get() = purgeFailures.last

    /** Seuil franchi : la dernière purge en échec, sinon `null`. Alerte de la déconnexion. */
    val blockedPurge: Flow<PurgeFailure?> get() = purgeFailures.blocked

    /** Changement de compte bloqué (`account.switch` laissé, seuil franchi), sinon `null`. Bandeau du Compte. */
    val blockedSwitch: Flow<PurgeFailure?> get() = purgeFailures.blockedSwitch

    /** [PURGE_FAILURE_THRESHOLD], sous le nom commun à iOS. */
    val purgeFailureThreshold: Int get() = PURGE_FAILURE_THRESHOLD

    /** `account.switch` effacé par un chemin quelconque : voir [PurgeFailureCounter.switchFlagCleared]. */
    fun switchFlagCleared() = purgeFailures.switchFlagCleared()

    private data class Profile(
        val email: String? = null,
        val displayName: String? = null,
    )

    val state: Flow<AccountState> =
        combine(kind.kind, profile, waitsForSession) { current, known, waiting ->
            val email = current == AccountKind.Email
            AccountState(
                kind = current,
                email = known.email.takeIf { email },
                displayName = known.displayName.takeIf { email },
                needsSignIn = email && waiting,
            )
        }

    /** Relit l'adresse (localement) et le prénom (serveur). Un échec garde ce qui était connu. */
    suspend fun refresh() {
        val remote = gateway ?: return
        if (kind.kind.value != AccountKind.Email) return
        val email = runCatching { remote.accountEmail() }.getOrNull()
        val name =
            try {
                remote.displayName()
            } catch (e: RemoteError) {
                Log.i(TAG, "Prénom non relu : ${e.message}")
                profile.value.displayName
            }
        profile.update { Profile(email ?: it.email, name) }
    }

    /** Nouveau prénom. Faux s'il est refusé (forme) ou s'il n'a pas pu partir (réseau). */
    @Suppress("ReturnCount") // Une garde par cas : serveur, forme, envoi.
    suspend fun setDisplayName(value: String): Boolean {
        val remote = gateway ?: return false
        val name = AccountLink.cleanedDisplayName(value) ?: return false
        return try {
            remote.setDisplayName(name)
            profile.update { it.copy(displayName = name) }
            true
        } catch (e: RemoteError) {
            Log.i(TAG, "Prénom non enregistré : ${e.message}")
            false
        }
    }

    /** Le compte a changé (connexion, déconnexion) : ce qui en était connu ne vaut plus. */
    fun forget() {
        profile.value = Profile()
    }

    companion object {
        private const val TAG = "AccountSession"

        /** Purges en échec à partir desquelles les écrans proposent de libérer de l'espace et « Nous écrire ». */
        const val PURGE_FAILURE_THRESHOLD = 3
    }
}

/** Pourquoi la déconnexion n'a pas eu lieu. */
enum class AccountSignOutError(
    val wireName: String,
) {
    /** Le réseau est exigé : rien n'a été retiré. */
    Offline("offline"),

    /** La purge de l'appareil n'est pas allée au bout : le drapeau reste, « Réessayer » la reprend. */
    Unknown("unknown"),
}

sealed interface AccountSignOutOutcome {
    data object SignedOut : AccountSignOutOutcome

    data class Failed(
        val error: AccountSignOutError,
    ) : AccountSignOutOutcome
}

/**
 * « Se déconnecter » (#87 §2.4), même règle qu'iOS. [prepare] envoie la file, arrête la synchronisation et compte ce
 * qui n'est pas parti (entrées `PENDING` et `FAILED`) : la confirmation prévient que ces modifications seront perdues,
 * sans refuser. Puis, comme la fin de « Supprimer mes données » (#68) : mode courses fermé, drapeau durable
 * [AccountSignOutFlag] posé, `signOut()`, [LocalDataPurge] (`account.kind` compris), nouveau compte anonyme vide, état
 * de l'app recréé, drapeau effacé. Tant que le drapeau existe, la purge est rejouée ([resumePending], au lancement ;
 * [run], « Réessayer ») ; un échec n'entraîne aucun redémarrage de l'app.
 */
class AccountSignOut(
    private val gateway: RemoteGateway,
    private val purge: LocalDataPurge,
    private val host: AccountDeletionHost,
    private val flag: AccountSignOutFlag,
    private val isOnline: () -> Boolean,
    /** Envoie ce qui peut l'être avant l'arrêt. */
    private val flush: suspend () -> Unit,
    /** Entrées de file restantes, `PENDING` et `FAILED`. */
    private val unsent: suspend () -> Int,
    private val timeout: Duration = 15.seconds,
    /** Compteur des purges en échec (`AccountSession`, #129). */
    private val failures: PurgeFailureRecorder? = null,
) {
    private val lock = Mutex()

    /** Une déconnexion a commencé et n'est pas finie (drapeau présent). Lit le disque : hors du fil principal. */
    val isPending: Boolean get() = flag.isPending

    /**
     * Avant la confirmation : file envoyée, synchronisation arrêtée, modifications restantes comptées. Ensuite [run] ou
     * [abandon].
     */
    @Suppress("TooGenericExceptionCaught") // Un envoi impossible n'empêche pas de compter ce qui reste.
    suspend fun prepare(): Int? =
        lock.withLock {
            try {
                flush()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.i(TAG, "Envoi avant déconnexion impossible : ${e.javaClass.simpleName}")
            }
            host.suspendSync()
            try {
                unsent()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // Base illisible : pas de confirmation, la synchronisation reprend (`null`).
                Log.w(TAG, "Modifications restantes non comptées : ${e.javaClass.simpleName}")
                host.resumeSync()
                null
            }
        }

    /**
     * Confirmation fermée : la synchronisation reprend. Sous le même verrou que [prepare] : un Retour pendant l'envoi
     * attend la fin de la préparation, sinon la reprise passerait avant l'arrêt et la synchro resterait arrêtée.
     */
    suspend fun abandon() = lock.withLock { host.resumeSync() }

    /** Après confirmation, ou « Réessayer » si le drapeau est déjà posé. */
    @Suppress("TooGenericExceptionCaught", "ReturnCount") // Toute panne locale reprend la synchronisation.
    suspend fun run(): AccountSignOutOutcome =
        lock.withLock {
            if (flag.isPending) return@withLock finish()
            if (!isOnline()) {
                host.resumeSync()
                return@withLock AccountSignOutOutcome.Failed(AccountSignOutError.Offline)
            }
            try {
                host.suspendSync()
                host.endShopping()
                purgeStep(PurgeStep.Preferences) { flag.write() }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Déconnexion interrompue : ${e.purgeCauseName}")
                // Même alerte que la purge (« Réessayer » seulement) : un stockage plein y bloque aussi (#129).
                failures?.purgeFailed(PurgeFailure(PurgeOperation.SignOut, e.failedPurgeStep))
                host.resumeSync()
                return@withLock AccountSignOutOutcome.Failed(AccountSignOutError.Unknown)
            }
            finish()
        }

    /** Au lancement : reprend une déconnexion interrompue. `null` s'il n'y en a pas. */
    suspend fun resumePending(): AccountSignOutOutcome? = lock.withLock { if (flag.isPending) finish() else null }

    /**
     * Rejouable : une session absente et une base vide le restent. Un échec garde le drapeau et monte le compteur des
     * purges en échec, avec sa première étape en échec (#129) ; une réussite le remet à 0.
     */
    @Suppress("TooGenericExceptionCaught") // Toute panne locale garde le drapeau : « Réessayer ».
    private suspend fun finish(): AccountSignOutOutcome {
        var purged = false
        return try {
            host.suspendSync()
            purgeStep(PurgeStep.Session) { gateway.signOut() }
            // Étapes attribuées dans la purge elle-même (base, catégories, préférences).
            purge.run()
            purgeStep(PurgeStep.Preferences) {
                host.clearLocalState()
                flag.clear()
            }
            purged = true
            failures?.purgeSucceeded()
            try {
                withTimeoutOrNull(timeout) { gateway.ensureSession() }
            } catch (e: RemoteError) {
                Log.i(TAG, "Nouveau compte reporté : ${e.message}")
            }
            host.rebuild()
            Log.i(TAG, "Déconnecté")
            AccountSignOutOutcome.SignedOut
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Purge de la déconnexion interrompue : ${e.purgeCauseName}")
            // Une panne après la purge (drapeau effacé, compteur remis à 0) n'est pas une purge en échec.
            if (!purged) failures?.purgeFailed(PurgeFailure(PurgeOperation.SignOut, e.failedPurgeStep))
            AccountSignOutOutcome.Failed(AccountSignOutError.Unknown)
        }
    }

    private companion object {
        const val TAG = "AccountSignOut"
    }
}
