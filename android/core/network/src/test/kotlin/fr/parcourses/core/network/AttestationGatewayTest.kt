package fr.parcourses.core.network

import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import kotlin.uuid.Uuid

/** Passerelle de `attest-device` (#137) contre un faux serveur : ce qui part, et comment les réponses sont lues. */
class AttestationGatewayTest {
    private val harness = GatewayHarness()
    private val server = harness.server
    private val gateway = harness.gateway
    private val challenge = "Q2hhbGxlbmdlRGUzMm9jdGV0c0VuQmFzZTY0VXJsMDA"

    @After
    fun tearDown() = harness.close()

    private fun body(request: HttpRequestData) = Json.parseToJsonElement((request.body as TextContent).text).jsonObject

    private fun attestRequests() = server.requests.filter { it.url.encodedPath.endsWith("/functions/v1/attest-device") }

    @Test
    fun theAccountOfAnAnonymousSessionIsAnonymous() =
        runBlocking<Unit> {
            gateway.ensureSession()

            val account = gateway.attestationAccount()

            assertEquals(Uuid.parse(server.userId), account.id)
            assertTrue(account.isAnonymous)
        }

    @Test
    fun theAccountOfAnEmailSessionIsNotAnonymous() =
        runBlocking<Unit> {
            server.email = "lea@exemple.fr"
            gateway.ensureSession()

            assertFalse(gateway.attestationAccount().isAnonymous)
        }

    @Test
    fun withoutSessionNoAccountIsCreated() =
        runBlocking<Unit> {
            try {
                gateway.attestationAccount()
                fail("aucune erreur levée")
            } catch (e: RemoteError.Unauthorized) {
                assertTrue(e.noLocalSession)
            }
            assertEquals(0, server.signUps)
        }

    @Test
    fun theChallengeStepSendsThePlatformWithTheUserToken() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST attest-device",
                FakeSupabase.Reply(body = """{"status":"challenge","challenge":"$challenge"}"""),
            )

            val reply = gateway.attestationChallenge()

            assertEquals(AttestationReply(200, "challenge", null, challenge), reply)
            val request = attestRequests().single()
            assertTrue(request.headers["Authorization"]!!.startsWith("Bearer ey"))
            assertEquals(
                JsonObject(mapOf("step" to JsonPrimitive("challenge"), "platform" to JsonPrimitive("android"))),
                body(request),
            )
        }

    @Test
    fun theVerifyStepSendsTheChallengeAndTheToken() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply("POST attest-device", FakeSupabase.Reply(body = """{"status":"attested"}"""))

            val reply = gateway.verifyAttestation(challenge, "jeton-play")

            assertEquals(AttestationReply(200, "attested", null, null), reply)
            assertEquals(
                JsonObject(
                    mapOf(
                        "step" to JsonPrimitive("verify"),
                        "platform" to JsonPrimitive("android"),
                        "challenge" to JsonPrimitive(challenge),
                        "token" to JsonPrimitive("jeton-play"),
                    ),
                ),
                body(attestRequests().single()),
            )
        }

    @Test
    fun aRefusalIsReturnedWithItsStatusAndCode() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST attest-device",
                FakeSupabase.Reply(HttpStatusCode.BadRequest, """{"error":"invalid_challenge"}"""),
                FakeSupabase.Reply(HttpStatusCode.BadGateway, "<html>passerelle</html>"),
            )

            val refused = gateway.verifyAttestation(challenge, "t")
            assertEquals(AttestationReply(400, null, "invalid_challenge", null), refused)
            // Corps illisible : seul le statut reste.
            assertEquals(AttestationReply(502, null, null, null), gateway.verifyAttestation(challenge, "t"))
        }

    @Test
    fun noResponseRaisesANetworkError() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.failWith = IOException("coupé")

            try {
                gateway.attestationChallenge()
                fail("aucune erreur levée")
            } catch (e: RemoteError) {
                assertTrue(e.toString(), e is RemoteError.Network)
            }
        }
}
