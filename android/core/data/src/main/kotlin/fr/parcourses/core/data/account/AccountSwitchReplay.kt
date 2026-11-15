package fr.parcourses.core.data.account

import android.util.Log
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.SyncCursors
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Reprise d'un changement de compte e-mail interrompu (drapeau `account.switch`, #87), au lancement et au retour au
 * premier plan. Sous [lock], le verrou de compte commun à `AccountLink.verify` : une reprise ne s'intercale jamais
 * pendant une vérification de code, et deux reprises ne purgent pas deux fois.
 *
 * - Aucune session : aucun nouveau compte à protéger. Le drapeau est effacé ; la comparaison entre le compte des
 *   données et le compte vérifié se fera à la prochaine connexion (« Se reconnecter »).
 * - Session anonyme (adresse absente) : rien à adopter, le drapeau est effacé.
 * - Session e-mail d'un autre compte que celui des données : purge rejouée, sans reprise, puis le compte est adopté
 *   ([SyncCursors.adopt], écrit tout de suite) et acquitté.
 * - Même compte : le drapeau est effacé.
 *
 * La session est lue sur l'appareil, sans rafraîchissement ni réseau. Stockage illisible : le drapeau reste, nouvel
 * essai au retour au premier plan.
 */
class AccountSwitchReplay(
    private val gateway: RemoteGateway,
    private val flag: AccountSwitchFlag,
    private val cursors: SyncCursors,
    private val kind: AccountKindFlag,
    private val lock: Mutex,
    /** Mode courses fermé, purge de l'appareil ([LocalDataPurge]) et préférences de la Live Update effacées. */
    private val purgeDevice: suspend () -> Unit,
) {
    /** Vrai si plus rien n'est à reprendre (drapeau absent ou effacé). */
    @Suppress("TooGenericExceptionCaught", "ReturnCount") // Toute panne garde le drapeau ; une garde par cas.
    suspend fun run(): Boolean =
        lock.withLock {
            if (!flag.isPending) return@withLock true
            try {
                // Lue dans le stockage, jamais importée : un rafraîchissement en cours ne la cache pas.
                val stored = gateway.storedSessionAccount()
                if (stored?.email != null && stored.accountId != cursors.accountId) {
                    val session = stored.accountId
                    purgeDevice()
                    kind.write(AccountKind.Email)
                    cursors.adopt(session, AccountKind.Email)
                    gateway.acknowledgeAccount(session)
                    Log.i(TAG, "Changement de compte e-mail repris")
                }
                flag.clear()
                true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Changement de compte non repris : ${e.javaClass.simpleName}")
                false
            }
        }

    private companion object {
        const val TAG = "AccountSwitchReplay"
    }
}

/**
 * « Continuer sans compte » d'un compte e-mail sans session (#87) : synchronisation arrêtée, mode courses fermé,
 * [LocalDataPurge] d'abord (rien du compte e-mail ne part vers l'anonyme), session oubliée, compte anonyme vide, état
 * de l'app recréé. Toute panne reprend la synchronisation, sans planter l'appelant.
 */
class ContinueWithoutAccount(
    private val gateway: RemoteGateway,
    private val purge: LocalDataPurge,
    private val host: AccountDeletionHost,
    /** Ce que l'app savait du compte (adresse, prénom) est oublié. */
    private val forget: () -> Unit = {},
) {
    @Suppress("TooGenericExceptionCaught") // Purge, SQLite ou réseau : la synchronisation reprend.
    suspend fun run(): Boolean =
        try {
            host.suspendSync()
            host.endShopping()
            purge.run()
            host.clearLocalState()
            gateway.signOutLocally()
            forget()
            try {
                gateway.ensureSession()
            } catch (e: RemoteError) {
                // Hors ligne : la synchronisation créera le compte anonyme plus tard.
                Log.i(TAG, "Compte anonyme reporté : ${e.message}")
            }
            host.rebuild()
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Compte anonyme non créé : ${e.javaClass.simpleName}")
            host.resumeSync()
            false
        }

    private companion object {
        const val TAG = "ContinueWithoutAccount"
    }
}
