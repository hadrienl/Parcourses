package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
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
 */
class AccountSession(
    private val gateway: RemoteGateway?,
    private val kind: AccountKindFlag,
    waitsForSession: Flow<Boolean> = flowOf(false),
) {
    private val profile = MutableStateFlow(Profile())

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

    private companion object {
        const val TAG = "AccountSession"
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
                flag.write()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Déconnexion interrompue : ${e.javaClass.simpleName}")
                host.resumeSync()
                return@withLock AccountSignOutOutcome.Failed(AccountSignOutError.Unknown)
            }
            finish()
        }

    /** Au lancement : reprend une déconnexion interrompue. `null` s'il n'y en a pas. */
    suspend fun resumePending(): AccountSignOutOutcome? = lock.withLock { if (flag.isPending) finish() else null }

    /** Rejouable : une session absente et une base vide le restent. Un échec garde le drapeau. */
    @Suppress("TooGenericExceptionCaught") // Toute panne locale garde le drapeau : « Réessayer ».
    private suspend fun finish(): AccountSignOutOutcome =
        try {
            host.suspendSync()
            gateway.signOut()
            purge.run()
            host.clearLocalState()
            flag.clear()
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
            Log.w(TAG, "Purge de la déconnexion interrompue : ${e.javaClass.simpleName}")
            AccountSignOutOutcome.Failed(AccountSignOutError.Unknown)
        }

    private companion object {
        const val TAG = "AccountSignOut"
    }
}
