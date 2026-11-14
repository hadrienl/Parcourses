package fr.parcourses.core.data.account

import fr.parcourses.core.data.sync.SessionLossAction
import fr.parcourses.core.data.sync.SyncDecisions
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlin.uuid.Uuid

/**
 * Passerelle de l'app, garde de toute création de compte, quel que soit l'appelant (lancement, synchronisation,
 * worker) :
 * - tant qu'une suppression du compte est en cours ([AccountDeletionFlag]), [ensureSession] refuse (`Unauthorized`)
 *   sans rien demander au serveur : un compte créé à ce moment recevrait, par la reprise de compte, les données qu'on
 *   est en train d'effacer ;
 * - pour un compte e-mail ([AccountKindFlag], #87 §2.4, vecteur `009`), [ensureSession] ne crée jamais de compte
 *   anonyme : sans session, `Unauthorized`, et la synchronisation attend la reconnexion.
 */
class DeletionGuardedGateway(
    private val inner: RemoteGateway,
    private val flag: AccountDeletionFlag,
    private val accountKind: AccountKindFlag? = null,
) : RemoteGateway by inner {
    override suspend fun ensureSession(captchaToken: String?): Uuid {
        if (flag.isPending) throw RemoteError.Unauthorized()
        val kind = accountKind?.kind?.value
        if (kind != null && SyncDecisions.sessionLossAction(kind) == SessionLossAction.WaitForSignIn) {
            // Session existante : celle du compte e-mail. Absente : aucune création.
            return inner.currentAccountId()
        }
        return inner.ensureSession(captchaToken)
    }
}
