package fr.parcourses.core.network

import fr.parcourses.core.network.FakeSupabase.Reply
import fr.parcourses.core.network.dto.EmailCodePurpose
import fr.parcourses.core.network.dto.ReviewSession
import io.github.jan.supabase.auth.user.UserInfo
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Compte de revue des stores (#149) : `review-sign-in` contre un faux serveur, ce qui part et la session reçue. */
class ReviewSignInGatewayTest {
    private val harness = GatewayHarness()
    private val server = harness.server
    private val gateway = harness.gateway
    private val reviewId = "cccccccc-0000-4000-8000-000000000003"
    private val expiresAt = 1_900_000_000L

    @After
    fun tearDown() = harness.close()

    private fun reviewRequests() =
        server.requests.filter { it.url.encodedPath.endsWith("/functions/v1/review-sign-in") }

    private fun body(request: HttpRequestData) = Json.parseToJsonElement((request.body as TextContent).text).jsonObject

    private fun grantedSession(): String =
        """{"access_token":"review-access","refresh_token":"review-refresh","expires_in":3600,""" +
            """"expires_at":$expiresAt,"token_type":"bearer","user_id":"$reviewId"}"""

    private suspend fun refusal(): AuthRequestError {
        try {
            gateway.verifyCode(REVIEW_EMAIL, "000000", EmailCodePurpose.Review)
        } catch (e: AuthRequestError) {
            return e
        }
        fail("aucun refus")
        error("unreachable")
    }

    @Test
    fun theFunctionGetsTheCodeWithThePublishableKeyOnlyAndItsSessionIsAdopted() =
        runBlocking<Unit> {
            val anonymous = gateway.ensureSession()
            server.reply("POST review-sign-in", Reply(body = grantedSession()))
            // `/user` avec le jeton reçu répond le compte de revue.
            server.userId = reviewId

            val verified = gateway.verifyCode(REVIEW_EMAIL, "123456", EmailCodePurpose.Review)

            assertEquals(Uuid.parse(reviewId), verified.accountId)
            // Le jeton de l'anonyme quitté est gardé avant la vérification, comme pour une connexion.
            assertNotNull(verified.previousAnonymousToken)
            val request = reviewRequests().single()
            assertEquals(HttpMethod.Post, request.method)
            assertEquals(listOf("publishable-key"), request.headers.getAll("apikey"))
            assertNull(request.headers[HttpHeaders.Authorization])
            assertEquals(ContentType.Application.Json, request.body.contentType?.withoutParameters())
            val sent = body(request)
            assertEquals(REVIEW_EMAIL, sent["email"]?.jsonPrimitive?.content)
            assertEquals("123456", sent["code"]?.jsonPrimitive?.content)
            // Ni GoTrue `/verify`, ni e-mail : seule la fonction vérifie le code.
            assertTrue(server.requests.none { it.url.encodedPath.endsWith("/auth/v1/verify") })
            val user = server.requests.last { it.url.encodedPath.endsWith("/auth/v1/user") }
            assertEquals("Bearer review-access", user.headers[HttpHeaders.Authorization])

            // Session enregistrée comme une autre : jetons, échéance et compte.
            val stored = checkNotNull(harness.store.read().session)
            assertEquals("review-access", stored.accessToken)
            assertEquals("review-refresh", stored.refreshToken)
            assertEquals(Instant.fromEpochSeconds(expiresAt), stored.expiresAt)
            assertEquals(reviewId, stored.user?.id)
            assertEquals(Uuid.parse(reviewId), gateway.sessionAccountId())
            // Le dernier compte connu est l'anonyme : la synchronisation reprendra les données.
            assertEquals(anonymous.toString(), harness.store.read().lastAccountId)
        }

    @Test
    fun everyRefusalIsAnAuthErrorAndTheAnonymousSessionStays() =
        runBlocking<Unit> {
            val anonymous = gateway.ensureSession()
            server.reply(
                "POST review-sign-in",
                Reply(HttpStatusCode.BadRequest, """{"error":"invalid_code"}"""),
                Reply(HttpStatusCode.MethodNotAllowed, ""),
                Reply(HttpStatusCode.InternalServerError, """{"error":"internal"}"""),
            )

            val invalid = refusal()
            assertEquals(400, invalid.status)
            assertEquals("invalid_code", invalid.code)
            val notAllowed = refusal()
            assertEquals(405, notAllowed.status)
            assertNull(notAllowed.code)
            val internal = refusal()
            assertEquals(500, internal.status)
            assertEquals("internal", internal.code)

            assertEquals(
                anonymous.toString(),
                harness.store
                    .read()
                    .session
                    ?.user
                    ?.id,
            )
            assertEquals(anonymous, gateway.currentAccountId())
        }

    @Test
    fun withoutNetworkTheCodeIsNotVerified() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.failWith = IOException("réseau coupé")
            try {
                gateway.verifyCode(REVIEW_EMAIL, "123456", EmailCodePurpose.Review)
                fail("aucune erreur levée")
            } catch (e: RemoteError) {
                assertTrue("attendu Network, reçu $e", e is RemoteError.Network)
            }
        }

    @Test
    fun theGrantedSessionIsReadWithItsExpiryAndNeverPrintsItsTokens() {
        val user = RemoteJson.decodeFromString(UserInfo.serializer(), """{"id":"$reviewId","aud":"authenticated"}""")
        val granted = RemoteJson.decodeFromString(ReviewSession.serializer(), grantedSession())

        val session = granted.toUserSession(user)

        assertEquals("review-access", session.accessToken)
        assertEquals("review-refresh", session.refreshToken)
        assertEquals(3600L, session.expiresIn)
        assertEquals("bearer", session.tokenType)
        assertEquals(Instant.fromEpochSeconds(expiresAt), session.expiresAt)
        assertEquals(reviewId, session.user?.id)
        assertEquals("ReviewSession($reviewId)", granted.toString())

        // Sans `expires_at` : échéance déduite de `expires_in`.
        val withoutExpiry =
            RemoteJson.decodeFromString(
                ReviewSession.serializer(),
                """{"access_token":"a","refresh_token":"r","expires_in":3600,"user_id":"$reviewId"}""",
            )
        assertTrue(withoutExpiry.toUserSession(user).expiresAt > Clock.System.now() + 59.minutes)
    }

    private companion object {
        const val REVIEW_EMAIL = "revue@parcourses.hadrien.eu"
    }
}
