package fr.parcourses.core.data.account

import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import kotlin.uuid.Uuid

/**
 * Passerelle de l'app : tant qu'une suppression du compte est en cours ([AccountDeletionFlag]), [ensureSession]
 * refuse (`Unauthorized`) sans rien demander au serveur, quel que soit l'appelant (lancement, synchronisation,
 * worker). Un compte créé à ce moment recevrait, par la reprise de compte, les données qu'on est en train d'effacer.
 */
class DeletionGuardedGateway(
    private val inner: RemoteGateway,
    private val flag: AccountDeletionFlag,
) : RemoteGateway by inner {
    override suspend fun ensureSession(captchaToken: String?): Uuid {
        if (flag.isPending) throw RemoteError.Unauthorized()
        return inner.ensureSession(captchaToken)
    }
}
