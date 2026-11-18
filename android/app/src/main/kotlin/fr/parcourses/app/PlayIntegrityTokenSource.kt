package fr.parcourses.app

import android.content.Context
import com.google.android.gms.tasks.Task
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityServiceException
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.model.IntegrityErrorCode
import fr.parcourses.core.data.attestation.AttestationOutcome
import fr.parcourses.core.data.attestation.IntegrityTokenResult
import fr.parcourses.core.data.attestation.IntegrityTokenSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Jeton Play Integrity en requête classique (#137) : le défi du serveur sert de nonce, tel quel. Sans numéro de projet
 * Cloud : l'app est distribuée par Play, et le projet est lié dans la Play Console. Aucune permission demandée.
 */
class PlayIntegrityTokenSource(
    context: Context,
) : IntegrityTokenSource {
    private val context = context.applicationContext

    @Suppress("TooGenericExceptionCaught") // Au mieux : une panne inattendue de la bibliothèque est passagère.
    override suspend fun token(nonce: String): IntegrityTokenResult =
        try {
            val request = IntegrityTokenRequest.builder().setNonce(nonce).build()
            val response = IntegrityManagerFactory.create(context).requestIntegrityToken(request).await()
            IntegrityTokenResult.Token(response.token())
        } catch (e: CancellationException) {
            throw e
        } catch (e: IntegrityServiceException) {
            IntegrityTokenResult.Failed(integrityErrorOutcome(e.errorCode))
        } catch (_: Exception) {
            IntegrityTokenResult.Failed(AttestationOutcome.Transient)
        }
}

/**
 * `IntegrityServiceException.errorCode` → issue (#137). Rien n'est jamais affiché : aucun dialogue de remédiation.
 * - `unsupported`, définitif : service absent ou inutilisable sur cet appareil ou pour cette installation ;
 * - `transient`, au lancement suivant (1 h au moins) : réseau, quota, panne passagère de Google ou du client ;
 * - `rejected`, 7 jours : nonce refusé, Play Store ou Play Services trop anciens (ils se mettent à jour seuls en
 *   arrière-plan : un nouvel essai a toutes les chances d'aboutir), et tout code inconnu d'une version future.
 */
internal fun integrityErrorOutcome(errorCode: Int): AttestationOutcome =
    when (errorCode) {
        IntegrityErrorCode.API_NOT_AVAILABLE,
        IntegrityErrorCode.PLAY_STORE_NOT_FOUND,
        IntegrityErrorCode.PLAY_SERVICES_NOT_FOUND,
        IntegrityErrorCode.CANNOT_BIND_TO_SERVICE,
        IntegrityErrorCode.APP_NOT_INSTALLED,
        IntegrityErrorCode.APP_UID_MISMATCH,
        IntegrityErrorCode.CLOUD_PROJECT_NUMBER_IS_INVALID,
        IntegrityErrorCode.PLAY_STORE_ACCOUNT_NOT_FOUND,
        -> AttestationOutcome.Unsupported

        IntegrityErrorCode.NETWORK_ERROR,
        IntegrityErrorCode.TOO_MANY_REQUESTS,
        IntegrityErrorCode.GOOGLE_SERVER_UNAVAILABLE,
        IntegrityErrorCode.CLIENT_TRANSIENT_ERROR,
        IntegrityErrorCode.INTERNAL_ERROR,
        -> AttestationOutcome.Transient

        else -> AttestationOutcome.Rejected
    }

/** Attend une `Task` de Play services. Une tâche annulée par Play lève une erreur ordinaire (issue passagère). */
private suspend fun <T> Task<T>.await(): T =
    suspendCancellableCoroutine { continuation ->
        addOnCompleteListener { task ->
            val error = task.exception
            when {
                error != null -> continuation.resumeWithException(error)
                task.isCanceled -> continuation.resumeWithException(IllegalStateException("Play Integrity annulé"))
                else -> continuation.resume(task.result)
            }
        }
    }
