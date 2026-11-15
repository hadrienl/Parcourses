package fr.parcourses.core.network

import fr.parcourses.core.model.ListRole
import io.ktor.client.request.HttpRequestData
import io.ktor.content.TextContent
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.uuid.Uuid

/** Passerelle du partage (#87, lot 87.6) contre un faux serveur : ce qui part, et comment les refus sont lus. */
class SharingGatewayTest {
    private val harness = GatewayHarness()
    private val server = harness.server
    private val gateway = harness.gateway
    private val list = Uuid.parse("33333333-3333-4333-8333-333333333333")

    @After
    fun tearDown() = harness.close()

    private fun body(request: HttpRequestData) = Json.parseToJsonElement((request.body as TextContent).text).jsonObject

    private suspend fun refusal(block: suspend () -> Unit): RemoteError {
        try {
            block()
        } catch (e: RemoteError) {
            return e
        }
        fail("aucune erreur levée")
        error("inaccessible")
    }

    @Test
    fun sendInvitationCallsTheEdgeFunctionWithTheUserToken() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST send-invitation",
                FakeSupabase.Reply(
                    body =
                        """{"invitation_id":"$list","link":"parcourses://invitation#abc","sent":false,
                        |"expires_at":"2026-11-21T10:00:00+00:00"}
                        """.trimMargin(),
                ),
            )
            val sent = gateway.sendInvitation(list, "lea@exemple.fr", ListRole.Viewer)
            assertFalse(sent.sent)
            assertEquals("parcourses://invitation#abc", sent.link)
            val request = server.requests.single { it.url.encodedPath.endsWith("/functions/v1/send-invitation") }
            assertTrue(request.headers["Authorization"]!!.startsWith("Bearer ey"))
            val json = body(request)
            assertEquals("viewer", json["role"]!!.jsonPrimitive.content)
            assertEquals(list.toString(), json["list_id"]!!.jsonPrimitive.content)
        }

    @Test
    fun aRefusalOfTheEdgeFunctionKeepsItsCode() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST send-invitation",
                FakeSupabase.Reply(HttpStatusCode.BadRequest, """{"error":"already_member","code":"P0001"}"""),
            )
            val error = refusal { gateway.sendInvitation(list, "lea@exemple.fr", ListRole.Editor) }
            assertEquals("already_member", (error as SharingRequestError).error)
        }

    @Test
    fun aRaisedRpcMessageBecomesASharingError() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST rpc/create_invitation",
                FakeSupabase.Reply(
                    HttpStatusCode.BadRequest,
                    """{"code":"P0001","message":"daily_limit","details":null,"hint":null}""",
                ),
            )
            val error = refusal { gateway.invitationLink(list, "lea@exemple.fr", ListRole.Editor) }
            assertEquals("daily_limit", (error as SharingRequestError).error)

            server.reply(
                "POST rpc/list_sharing",
                FakeSupabase.Reply(
                    HttpStatusCode.Forbidden,
                    """{"code":"42501","message":"not allowed","details":null,"hint":null}""",
                ),
            )
            assertTrue(refusal { gateway.listSharing(list) } is RemoteError.Forbidden)
        }

    @Test
    fun copyingALinkBuildsItFromTheNewToken() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST rpc/create_invitation",
                FakeSupabase.Reply(
                    body =
                        """[{"invitation_id":"$list","invitee_email":"lea@exemple.fr","token":"tok",
                        |"expires_at":"2026-11-21T10:00:00+00:00","sender_name":"Hadrien"}]
                        """.trimMargin(),
                ),
            )
            assertEquals("parcourses://invitation#tok", gateway.invitationLink(list, "lea@exemple.fr", ListRole.Editor))
            val json = body(server.restRequests().single())
            assertEquals("false", json["p_send_email"]!!.jsonPrimitive.content)
        }

    /** Lot 87.7 : avec l'hôte des App Links, « Copier le lien » donne `https://<hôte>/i/#<jeton>`. */
    @Test
    fun copyingALinkUsesTheHttpsHostWhenConfigured() =
        runBlocking<Unit> {
            val withHost = GatewayHarness(invitationLinks = InvitationLinks("parcourses.hadrien.eu"))
            try {
                withHost.gateway.ensureSession()
                withHost.server.reply(
                    "POST rpc/create_invitation",
                    FakeSupabase.Reply(
                        body =
                            """[{"invitation_id":"$list","invitee_email":"lea@exemple.fr","token":"tok",
                            |"expires_at":"2026-11-21T10:00:00+00:00","sender_name":"Hadrien"}]
                            """.trimMargin(),
                    ),
                )
                assertEquals(
                    "https://parcourses.hadrien.eu/i/#tok",
                    withHost.gateway.invitationLink(list, "lea@exemple.fr", ListRole.Editor),
                )
            } finally {
                withHost.close()
            }
        }

    @Test
    fun listSharingIsDecodedWithItsRoles() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST rpc/list_sharing",
                FakeSupabase.Reply(
                    body =
                        """{"list_id":"$list","role":"owner",
                        |"owner":{"user_id":"${server.userId}","display_name":"Hadrien","is_me":true},
                        |"members":[{"user_id":"22222222-2222-4222-8222-222222222222","display_name":"Léa",
                        |"role":"viewer","is_me":false,"joined_at":"2026-11-12T10:00:00+00:00"}],
                        |"invitations":[{"id":"44444444-4444-4444-8444-444444444444","email":"c@exemple.fr",
                        |"role":"editor","created_at":"2026-11-14T10:00:00+00:00",
                        |"expires_at":"2026-11-21T10:00:00+00:00","sent_count":1,"expired":false}]}
                        """.trimMargin(),
                ),
            )
            val sharing = gateway.listSharing(list)
            assertEquals(ListRole.Owner, sharing.role)
            assertEquals(listOf(ListRole.Owner, ListRole.Viewer), sharing.participants.map { it.role })
            assertEquals("c@exemple.fr", sharing.invitations.single().email)
        }

    @Test
    fun anAcceptanceIsReadFromItsStatus() =
        runBlocking<Unit> {
            gateway.ensureSession()
            server.reply(
                "POST rpc/accept_invitation",
                FakeSupabase.Reply(body = """[{"status":"accepted","list_id":"$list","role":"editor"}]"""),
            )
            val accepted = gateway.acceptInvitation(Uuid.random())
            assertEquals("accepted", accepted.status)
            assertEquals(ListRole.Editor, accepted.role)
            val json = body(server.restRequests().single())
            assertTrue(json.containsKey("p_invitation_id"))
        }

    @Test
    fun aSignalCarriesNoLabel() {
        val signal =
            signalOf(
                Json.parseToJsonElement("""{"id":1,"list_id":"$list","kind":"items"}""").jsonObject,
            )
        assertEquals(RealtimeEvent.Changed(list, "items"), signal)
        assertEquals(
            RealtimeEvent.Changed(null, "invitations"),
            signalOf(Json.parseToJsonElement("""{"list_id":null,"kind":"invitations"}""").jsonObject),
        )
    }
}
