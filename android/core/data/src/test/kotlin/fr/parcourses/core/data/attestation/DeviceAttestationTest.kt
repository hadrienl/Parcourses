package fr.parcourses.core.data.attestation

import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.network.AttestationAccount
import fr.parcourses.core.network.AttestationGateway
import fr.parcourses.core.network.AttestationReply
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.time.Clock
import kotlin.time.Duration.Companion.days
import kotlin.time.Duration.Companion.hours
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Déroulé de l'attestation d'appareil (#137) avec une passerelle, un jeton et une horloge doublés. */
@RunWith(AndroidJUnit4::class) // `android.util.Log` en cas de panne
class DeviceAttestationTest {
    private val account = Uuid.parse("aaaaaaaa-0000-4000-8000-000000000001")
    private val now = Instant.parse("2026-11-18T10:00:00Z")
    private val challenge = "c".repeat(43)
    private val gateway = FakeAttestationGateway(AttestationAccount(account, isAnonymous = true))
    private val tokens = FakeTokenSource(IntegrityTokenResult.Token("jeton-play"))
    private val store = InMemoryAttestationStore()
    private var busy = false

    private val clock =
        object : Clock {
            override fun now(): Instant = now
        }

    private val attestation = DeviceAttestation(gateway, tokens, store, clock, isAccountBusy = { busy })

    private fun challengeReply() = AttestationReply(200, "challenge", null, challenge)

    @Test
    fun aSuccessfulAttemptSendsTheChallengeAsNonceAndRecordsAttested() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            gateway.verifyReplies += AttestationReply(200, "attested", null, null)

            assertEquals(AttestationOutcome.Attested, attestation.runOnce())

            // Le défi est le nonce, tel quel, puis il repart avec le jeton.
            assertEquals(listOf(challenge), tokens.nonces)
            assertEquals(listOf(challenge to "jeton-play"), gateway.verifications)
            assertEquals(AttestationState(AttestationStatus.Attested, null), store.read(account))

            // Définitif : plus rien au lancement suivant.
            assertNull(attestation.runOnce())
            assertEquals(1, gateway.challenges)
        }

    @Test
    fun aServerWithoutSecretsIsRetriedAfterADay() =
        runBlocking {
            gateway.challengeReplies += AttestationReply(200, "not_configured", null, null)

            assertEquals(AttestationOutcome.NotConfigured, attestation.runOnce())

            assertTrue(tokens.nonces.isEmpty())
            assertEquals(AttestationState(AttestationStatus.Pending, now + 24.hours), store.read(account))
        }

    @Test
    fun aRejectedProofIsRetriedAfterAWeek() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            gateway.verifyReplies += AttestationReply(400, null, "rejected", null)

            assertEquals(AttestationOutcome.Rejected, attestation.runOnce())

            assertEquals(AttestationState(AttestationStatus.Pending, now + 7.days), store.read(account))
        }

    @Test
    fun noNetworkIsTransientAndWaitsAnHour() =
        runBlocking {
            gateway.challengeError = RemoteError.Network(notSent = true)

            assertEquals(AttestationOutcome.Transient, attestation.runOnce())

            assertTrue(tokens.nonces.isEmpty())
            assertEquals(AttestationState(AttestationStatus.Pending, now + 1.hours), store.read(account))
        }

    @Test
    fun aLostVerificationIsTransient() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            gateway.verifyError = RemoteError.Network()

            assertEquals(AttestationOutcome.Transient, attestation.runOnce())
            assertEquals(AttestationStatus.Pending, store.read(account)?.status)
        }

    @Test
    fun anEmailAccountSendsNothing() =
        runBlocking {
            gateway.account = AttestationAccount(account, isAnonymous = false)

            assertNull(attestation.runOnce())

            assertEquals(0, gateway.challenges)
            assertTrue(tokens.nonces.isEmpty())
            assertNull(store.read(account))
        }

    @Test
    fun withoutPlayServicesTheDeviceIsUnsupportedForGood() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            tokens.result = IntegrityTokenResult.Failed(AttestationOutcome.Unsupported)

            assertEquals(AttestationOutcome.Unsupported, attestation.runOnce())

            // Ni vérification, ni nouvel essai.
            assertTrue(gateway.verifications.isEmpty())
            assertEquals(AttestationState(AttestationStatus.Unsupported, null), store.read(account))
            assertNull(attestation.runOnce())
            assertEquals(1, gateway.challenges)
        }

    @Test
    fun aPendingAttemptWaitsForItsDueDate() =
        runBlocking {
            store.write(account, AttestationState(AttestationStatus.Pending, now + 1.hours))

            assertNull(attestation.runOnce())
            assertEquals(0, gateway.challenges)

            // Échéance atteinte : nouvelle tentative.
            store.write(account, AttestationState(AttestationStatus.Pending, now))
            gateway.challengeReplies += AttestationReply(200, "attested", null, null)
            assertEquals(AttestationOutcome.Attested, attestation.runOnce())
            assertEquals(AttestationStatus.Attested, store.read(account)?.status)
        }

    @Test
    fun anUnreadableSessionTriesNothingAndRecordsNothing() =
        runBlocking {
            gateway.accountError = RemoteError.Unauthorized(noLocalSession = true)

            assertNull(attestation.runOnce())

            assertEquals(0, gateway.challenges)
            assertNull(store.read(account))
        }

    @Test
    fun aDeletionInProgressStopsEverything() =
        runBlocking {
            busy = true

            assertNull(attestation.runOnce())

            assertEquals(0, gateway.challenges)
        }

    @Test
    fun anAccountLeftDuringTheAttemptIsNotRewritten() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            gateway.verifyReplies += AttestationReply(200, "attested", null, null)
            // La purge passe pendant la demande du jeton.
            tokens.onRequest = { busy = true }

            assertEquals(AttestationOutcome.Attested, attestation.runOnce())

            assertNull(store.read(account))
        }

    @Test
    fun anotherAccountAfterTheAttemptGetsNothingWritten() =
        runBlocking {
            gateway.challengeReplies += challengeReply()
            gateway.verifyReplies += AttestationReply(200, "attested", null, null)
            // Connexion à un compte e-mail pendant la demande du jeton.
            val other = Uuid.parse("bbbbbbbb-0000-4000-8000-000000000002")
            tokens.onRequest = { gateway.account = AttestationAccount(other, isAnonymous = false) }

            assertEquals(AttestationOutcome.Attested, attestation.runOnce())

            assertNull(store.read(account))
            assertNull(store.read(other))
        }

    @Test
    fun aChallengeWithoutValueIsTransient() =
        runBlocking {
            gateway.challengeReplies += AttestationReply(200, "challenge", null, null)

            assertEquals(AttestationOutcome.Transient, attestation.runOnce())
            assertTrue(tokens.nonces.isEmpty())
        }

    @Test
    fun aStoreThatCannotWriteRaisesNothing() =
        runBlocking {
            gateway.challengeReplies += AttestationReply(200, "attested", null, null)
            val failing =
                object : AttestationStore by store {
                    override fun write(
                        accountId: Uuid,
                        state: AttestationState,
                    ) {
                        error("disque plein")
                    }
                }

            assertNull(DeviceAttestation(gateway, tokens, failing, clock).runOnce())
        }
}

/** Passerelle doublée : réponses en file, appels comptés. */
private class FakeAttestationGateway(
    var account: AttestationAccount,
) : AttestationGateway {
    var accountError: RemoteError? = null
    var challengeError: RemoteError? = null
    var verifyError: RemoteError? = null
    val challengeReplies = ArrayDeque<AttestationReply>()
    val verifyReplies = ArrayDeque<AttestationReply>()
    var challenges = 0
    val verifications = mutableListOf<Pair<String, String>>()

    override suspend fun attestationAccount(): AttestationAccount {
        accountError?.let { throw it }
        return account
    }

    override suspend fun attestationChallenge(): AttestationReply {
        challenges++
        challengeError?.let { throw it }
        return challengeReplies.removeFirst()
    }

    override suspend fun verifyAttestation(
        challenge: String,
        token: String,
    ): AttestationReply {
        verifications += challenge to token
        verifyError?.let { throw it }
        return verifyReplies.removeFirst()
    }
}

private class FakeTokenSource(
    var result: IntegrityTokenResult,
) : IntegrityTokenSource {
    val nonces = mutableListOf<String>()
    var onRequest: () -> Unit = {}

    override suspend fun token(nonce: String): IntegrityTokenResult {
        nonces += nonce
        onRequest()
        return result
    }
}
