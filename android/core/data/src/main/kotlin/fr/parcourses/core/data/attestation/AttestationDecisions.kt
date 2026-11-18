package fr.parcourses.core.data.attestation

import kotlin.time.Duration
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Instant

/** Statut persisté de l'attestation d'un compte (#137). `attested` et `unsupported` sont définitifs. */
enum class AttestationStatus(
    val wireName: String,
) {
    Pending("pending"),
    Attested("attested"),
    Unsupported("unsupported"),
    ;

    companion object {
        fun fromWireName(value: String?): AttestationStatus? = entries.firstOrNull { it.wireName == value }
    }
}

/** État de l'attestation d'un compte, persisté par id de compte. Aucun état : première tentative. */
data class AttestationState(
    val status: AttestationStatus,
    /** Prochaine tentative au plus tôt, seulement pour [AttestationStatus.Pending]. */
    val nextAttemptAt: Instant?,
)

/** Issue d'une tentative. Mêmes noms qu'iOS (`AttestationOutcome`). */
enum class AttestationOutcome(
    val wireName: String,
) {
    Attested("attested"),

    /** Service absent sur l'appareil (Play Store ou Play Services absents ou trop anciens…) : jamais retenté. */
    Unsupported("unsupported"),

    /** Réseau, 5xx, 401, erreur passagère de Play : reprise au lancement suivant, au plus tôt 1 h après. */
    Transient("transient"),

    /** Secrets absents sur le serveur : 24 h. */
    NotConfigured("notConfigured"),

    /** Preuve refusée, défi invalide ou requête refusée : 7 jours. */
    Rejected("rejected"),
}

/** Étape du protocole `attest-device`. */
enum class AttestationStep(
    val wireName: String,
) {
    Challenge("challenge"),
    Verify("verify"),
}

/** Lecture d'une réponse de `attest-device` (vecteur `003`) : passer à la preuve, ou une issue. */
sealed interface AttestationResponse {
    /** Défi reçu : demander la preuve à Play Integrity. Seulement à l'étape [AttestationStep.Challenge]. */
    data object Proceed : AttestationResponse

    /** Fin de la tentative. */
    data class Outcome(
        val outcome: AttestationOutcome,
    ) : AttestationResponse
}

/**
 * Décisions de l'attestation d'appareil, pures et partagées avec iOS (`enum AttestationDecisions`) : vérifiées par les
 * vecteurs de `shared/test-vectors/attestation/`.
 */
object AttestationDecisions {
    /** Délai après un échec passager. */
    val TRANSIENT_DELAY: Duration = 1.hours

    /** Délai quand le serveur n'est pas configuré. */
    val NOT_CONFIGURED_DELAY: Duration = 24.hours

    /** Délai après un refus. */
    val REJECTED_DELAY: Duration = 7.days

    private const val HTTP_SUCCESS_MIN = 200
    private const val HTTP_SUCCESS_MAX = 299
    private const val HTTP_BAD_REQUEST = 400

    /** Corps `status` de `attest-device`. */
    private const val STATUS_CHALLENGE = "challenge"
    private const val STATUS_ATTESTED = "attested"
    private const val STATUS_NOT_CONFIGURED = "not_configured"

    /**
     * Vecteur `001` : seulement pour un compte anonyme (rien n'est envoyé à Google pour un compte e-mail). Aucun état :
     * oui. `attested` et `unsupported` : jamais. `pending` : dès que l'échéance est atteinte (bornes comprises).
     */
    fun shouldAttempt(
        isAnonymous: Boolean,
        state: AttestationState?,
        now: Instant,
    ): Boolean {
        // `pending` sans échéance (jamais écrit ainsi) : tentative, plutôt qu'un compte bloqué pour toujours.
        val due = state == null || (state.status == AttestationStatus.Pending && (state.nextAttemptAt ?: now) <= now)
        return isAnonymous && due
    }

    /** Vecteur `002`. */
    fun nextState(
        outcome: AttestationOutcome,
        now: Instant,
    ): AttestationState =
        when (outcome) {
            AttestationOutcome.Attested -> AttestationState(AttestationStatus.Attested, null)
            AttestationOutcome.Unsupported -> AttestationState(AttestationStatus.Unsupported, null)
            AttestationOutcome.Transient -> AttestationState(AttestationStatus.Pending, now + TRANSIENT_DELAY)
            AttestationOutcome.NotConfigured -> AttestationState(AttestationStatus.Pending, now + NOT_CONFIGURED_DELAY)
            AttestationOutcome.Rejected -> AttestationState(AttestationStatus.Pending, now + REJECTED_DELAY)
        }

    /**
     * Vecteur `003`. [httpStatus] 0 : pas de réponse. [status] et [error] : champs du corps JSON, nuls s'ils manquent.
     * Un 400 est un refus du serveur (défi invalide, preuve refusée, corps refusé) ; tout autre échec est passager, de
     * même qu'un défi reçu à la vérification. Même règle qu'iOS : [error] ne départage rien aujourd'hui.
     */
    @Suppress("UnusedParameter") // signature commune aux deux plateformes et aux vecteurs
    fun responseOutcome(
        step: AttestationStep,
        httpStatus: Int,
        status: String?,
        error: String?,
    ): AttestationResponse {
        if (httpStatus !in HTTP_SUCCESS_MIN..HTTP_SUCCESS_MAX) {
            val refused = httpStatus == HTTP_BAD_REQUEST
            return AttestationResponse.Outcome(
                if (refused) AttestationOutcome.Rejected else AttestationOutcome.Transient,
            )
        }
        return when {
            status == STATUS_CHALLENGE && step == AttestationStep.Challenge -> AttestationResponse.Proceed
            status == STATUS_ATTESTED -> AttestationResponse.Outcome(AttestationOutcome.Attested)
            status == STATUS_NOT_CONFIGURED -> AttestationResponse.Outcome(AttestationOutcome.NotConfigured)
            else -> AttestationResponse.Outcome(AttestationOutcome.Transient)
        }
    }
}
