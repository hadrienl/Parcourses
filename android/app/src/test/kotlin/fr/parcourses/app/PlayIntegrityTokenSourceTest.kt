package fr.parcourses.app

import com.google.android.play.core.integrity.model.IntegrityErrorCode
import fr.parcourses.core.data.attestation.AttestationOutcome
import org.junit.Assert.assertEquals
import org.junit.Test

/** Codes d'erreur de Play Integrity → issue de l'attestation (#137). */
class PlayIntegrityTokenSourceTest {
    @Test
    fun aMissingOrUnusableServiceIsUnsupported() {
        val codes =
            listOf(
                IntegrityErrorCode.API_NOT_AVAILABLE,
                IntegrityErrorCode.PLAY_STORE_NOT_FOUND,
                IntegrityErrorCode.PLAY_SERVICES_NOT_FOUND,
                IntegrityErrorCode.APP_NOT_INSTALLED,
                IntegrityErrorCode.APP_UID_MISMATCH,
                IntegrityErrorCode.CLOUD_PROJECT_NUMBER_IS_INVALID,
            )
        codes.forEach { assertEquals("code $it", AttestationOutcome.Unsupported, integrityErrorOutcome(it)) }
    }

    @Test
    fun aPassingFailureIsTransient() {
        val codes =
            listOf(
                IntegrityErrorCode.NETWORK_ERROR,
                IntegrityErrorCode.TOO_MANY_REQUESTS,
                IntegrityErrorCode.GOOGLE_SERVER_UNAVAILABLE,
                IntegrityErrorCode.CLIENT_TRANSIENT_ERROR,
                IntegrityErrorCode.INTERNAL_ERROR,
                IntegrityErrorCode.CANNOT_BIND_TO_SERVICE,
            )
        codes.forEach { assertEquals("code $it", AttestationOutcome.Transient, integrityErrorOutcome(it)) }
    }

    /** Nonce refusé, Play trop ancien (il se met à jour seul), Play Store sans compte ou code inconnu : 7 jours. */
    @Test
    fun aRefusedNonceOrAnOutdatedPlayIsRetriedLater() {
        val codes =
            listOf(
                IntegrityErrorCode.NONCE_TOO_SHORT,
                IntegrityErrorCode.NONCE_TOO_LONG,
                IntegrityErrorCode.NONCE_IS_NOT_BASE64,
                IntegrityErrorCode.PLAY_STORE_VERSION_OUTDATED,
                IntegrityErrorCode.PLAY_SERVICES_VERSION_OUTDATED,
                IntegrityErrorCode.PLAY_STORE_ACCOUNT_NOT_FOUND,
                -999,
            )
        codes.forEach { assertEquals("code $it", AttestationOutcome.Rejected, integrityErrorOutcome(it)) }
    }
}
