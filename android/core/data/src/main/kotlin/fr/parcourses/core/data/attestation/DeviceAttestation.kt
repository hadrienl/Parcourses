package fr.parcourses.core.data.attestation

import android.util.Log
import fr.parcourses.core.network.AttestationGateway
import fr.parcourses.core.network.AttestationReply
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CancellationException
import kotlin.time.Clock
import kotlin.uuid.Uuid

/** Jeton Play Integrity pour un défi, ou l'issue d'un échec déjà classée. */
sealed interface IntegrityTokenResult {
    data class Token(
        val value: String,
    ) : IntegrityTokenResult

    data class Failed(
        val outcome: AttestationOutcome,
    ) : IntegrityTokenResult
}

/** Fournisseur du jeton d'intégrité : Play Integrity dans l'app, une doublure dans les tests. Ne lève jamais. */
fun interface IntegrityTokenSource {
    /** [nonce] : le défi du serveur, tel quel (base64url de 43 caractères). */
    suspend fun token(nonce: String): IntegrityTokenResult
}

/**
 * Attestation de l'appareil par Play Integrity (#137), en requête classique : une tentative par lancement, après
 * l'ouverture de session, seulement pour un compte anonyme et quand [AttestationDecisions.shouldAttempt] le permet.
 * Rien n'est affiché ni remonté : l'issue est seulement persistée pour le compte ([AttestationStore]).
 *
 * Déroulé : défi de `attest-device`, jeton Play Integrity avec ce défi pour nonce, vérification par `attest-device`,
 * puis [AttestationDecisions.nextState].
 */
class DeviceAttestation(
    private val gateway: AttestationGateway,
    private val tokens: IntegrityTokenSource,
    private val store: AttestationStore,
    private val clock: Clock = Clock.System,
    /** Suppression, déconnexion ou changement de compte en cours : ni tentative, ni écriture (la purge passe). */
    private val isAccountBusy: () -> Boolean = { false },
) {
    /**
     * Une tentative si elle est due. Renvoie son issue, `null` si rien n'a été tenté. Ne lève jamais, sauf
     * l'annulation : toute panne est passagère.
     */
    @Suppress("TooGenericExceptionCaught") // Au mieux : aucune panne ne remonte, elle est seulement retentée.
    suspend fun runOnce(): AttestationOutcome? {
        if (isAccountBusy()) return null
        return try {
            val account = gateway.attestationAccount()
            if (!AttestationDecisions.shouldAttempt(account.isAnonymous, store.read(account.id), clock.now())) {
                null
            } else {
                val outcome = attempt()
                // Compte parti ou changé pendant la tentative (purge, connexion) : l'issue n'est plus la sienne.
                if (isStillCurrent(account.id)) {
                    store.write(account.id, AttestationDecisions.nextState(outcome, clock.now()))
                }
                outcome
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Session illisible, préférences non écrites… : le lancement suivant réessaiera. Ni jeton ni défi ici.
            Log.i(TAG, "Attestation reportée : ${e.javaClass.simpleName}")
            null
        }
    }

    @Suppress("ReturnCount") // une sortie par étape du protocole
    private suspend fun attempt(): AttestationOutcome {
        val challengeReply = call(AttestationStep.Challenge) { gateway.attestationChallenge() }
        val challenge =
            when (challengeReply) {
                is Step.Done -> return challengeReply.outcome

                // Défi annoncé mais absent : réponse illisible, passagère.
                is Step.Proceed -> challengeReply.challenge ?: return AttestationOutcome.Transient
            }
        val token =
            when (val result = tokens.token(challenge)) {
                is IntegrityTokenResult.Token -> result.value
                is IntegrityTokenResult.Failed -> return result.outcome
            }
        return when (val verified = call(AttestationStep.Verify) { gateway.verifyAttestation(challenge, token) }) {
            is Step.Done -> verified.outcome

            // Jamais à la vérification (vecteur `003`) : par prudence, passager.
            is Step.Proceed -> AttestationOutcome.Transient
        }
    }

    private suspend fun isStillCurrent(accountId: Uuid): Boolean =
        !isAccountBusy() &&
            try {
                gateway.attestationAccount().id == accountId
            } catch (_: RemoteError) {
                false
            }

    /** Appel de `attest-device` lu par [AttestationDecisions.responseOutcome]. Pas de réponse : statut 0. */
    private suspend fun call(
        step: AttestationStep,
        request: suspend () -> AttestationReply,
    ): Step {
        val reply =
            try {
                request()
            } catch (_: RemoteError) {
                AttestationReply(httpStatus = 0, status = null, error = null, challenge = null)
            }
        val response = AttestationDecisions.responseOutcome(step, reply.httpStatus, reply.status, reply.error)
        return when (response) {
            AttestationResponse.Proceed -> Step.Proceed(reply.challenge?.takeIf { it.isNotBlank() })
            is AttestationResponse.Outcome -> Step.Done(response.outcome)
        }
    }

    private sealed interface Step {
        data class Proceed(
            val challenge: String?,
        ) : Step

        data class Done(
            val outcome: AttestationOutcome,
        ) : Step
    }

    private companion object {
        const val TAG = "DeviceAttestation"
    }
}
