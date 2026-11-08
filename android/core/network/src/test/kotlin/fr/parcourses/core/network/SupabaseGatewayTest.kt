package fr.parcourses.core.network

import fr.parcourses.core.network.FakeSupabase.Reply
import fr.parcourses.core.network.dto.CheckUpload
import fr.parcourses.core.network.dto.GraphSnapshotResponse
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.VisitAccess
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
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
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Le gateway contre un faux serveur HTTP : ce qui part sur le fil, et ce que l'app en retient. */
class SupabaseGatewayTest {
    private val harness = GatewayHarness()
    private val server = harness.server
    private val gateway = harness.gateway
    private val id = Uuid.parse("11111111-1111-4111-8111-111111111111")
    private val now = Instant.parse("2026-11-08T10:00:00Z")

    @After
    fun tearDown() = harness.close()

    private suspend inline fun <reified E : RemoteError> expectError(block: () -> Unit): E {
        try {
            block()
        } catch (e: RemoteError) {
            assertTrue("attendu ${E::class.simpleName}, reçu $e", e is E)
            return e as E
        }
        fail("aucune erreur levée")
        error("unreachable")
    }

    private fun json(text: String) = kotlinx.serialization.json.Json.parseToJsonElement(text)

    // region Session

    @Test
    fun ensureSessionCreatesOneAnonymousAccountEvenWhenCalledConcurrently() = runBlocking<Unit> {
        val ids = (1..4).map { async { gateway.ensureSession() } }.awaitAll()
        assertEquals(1, server.signUps)
        assertEquals(setOf(Uuid.parse(server.userId)), ids.toSet())
        val signUp = server.requests.first { it.url.encodedPath.endsWith("/signup") }
        assertEquals("publishable-key", signUp.headers["apikey"])
        assertEquals(server.userId, harness.store.read().lastAccountId)
        assertNotNull(harness.store.read().session)
    }

    @Test
    fun theSessionSurvivesARestart() = runBlocking<Unit> {
        gateway.ensureSession()
        val restarted = GatewayHarness(FakeSupabase(), harness.store)
        try {
            assertEquals(Uuid.parse(server.userId), restarted.gateway.ensureSession())
            assertEquals(0, restarted.server.signUps)
        } finally {
            restarted.close()
        }
    }

    @Test
    fun withoutSessionARequestCreatesNoAccountAndSendsNothing() = runBlocking<Unit> {
        expectError<RemoteError.Unauthorized> { gateway.fetchLists(null) }
        expectError<RemoteError.Unauthorized> { gateway.saveList(ListUpsert(id, "Sans session")) }
        expectError<RemoteError.Unauthorized> { gateway.currentAccountId() }
        expectError<RemoteError.Unauthorized> { gateway.sessionAccountId() }
        assertEquals(0, server.signUps)
        assertTrue(server.restRequests().isEmpty())
    }

    @Test
    fun aSessionOfAnotherAccountIsReportedNotUsed() = runBlocking<Unit> {
        gateway.ensureSession()
        harness.store.update { it.copy(lastAccountId = "bbbbbbbb-0000-4000-8000-000000000002") }
        expectError<RemoteError.AccountChanged> { gateway.fetchLists(null) }
        expectError<RemoteError.AccountChanged> { gateway.ensureSession() }
        // Le compte réel reste lisible pour réidentifier les données locales.
        val actual = gateway.sessionAccountId()
        gateway.acknowledgeAccount(actual)
        assertEquals(emptyList<Any>(), gateway.fetchLists(null))
    }

    @Test
    fun requestsCarryTheApiKeyAndTheUserToken() = runBlocking<Unit> {
        gateway.ensureSession()
        gateway.fetchCategories()
        val request = server.restRequests().single()
        assertEquals("publishable-key", request.headers["apikey"])
        assertTrue(request.headers["Authorization"]!!.startsWith("Bearer ey"))
    }

    @Test
    fun serverDateComesFromTheHttpHeader() = runBlocking<Unit> {
        gateway.ensureSession()
        server.reply("GET categories", Reply(headers = mapOf("Date" to "Sun, 08 Nov 2026 10:00:00 GMT")))
        assertEquals(now, gateway.serverDate())
    }

    // endregion

    // region Écritures

    @Test
    fun savingAListUpdatesThenInsertsOnlyWhenMissing() = runBlocking<Unit> {
        gateway.ensureSession()
        // Absente : mise à jour vide, puis insertion « on conflict do nothing ».
        gateway.saveList(ListUpsert(id, "Courses"))
        val (patch, post) = server.restRequests()
        assertEquals("PATCH", patch.method.value)
        assertEquals("eq.$id", patch.url.parameters["id"])
        assertEquals("""{"name":"Courses"}""", server.bodyOf(patch))
        assertEquals("POST", post.method.value)
        assertEquals("id", post.url.parameters["on_conflict"])
        assertTrue(post.headers["Prefer"]!!.contains("resolution=ignore-duplicates"))
        assertEquals("""[{"id":"$id","name":"Courses"}]""", server.bodyOf(post))

        // Existante : une mise à jour suffit.
        server.requests.clear()
        server.reply("PATCH lists", Reply(body = """[{"id":"$id"}]"""))
        gateway.saveList(ListUpsert(id, "Renommée"))
        assertEquals(listOf("PATCH"), server.restRequests().map { it.method.value })
    }

    @Test
    fun checksAreSentInOneIdempotentBatchWithExplicitNulls() = runBlocking<Unit> {
        gateway.ensureSession()
        server.reply("GET categories", Reply(body = """[{"id":4,"slug":"dairy","name":"C","default_rank":70}]"""))
        val product = Uuid.parse("22222222-2222-4222-8222-222222222222")
        gateway.insertChecks(
            listOf(
                CheckUpload(id, id, CheckUpload.Target.Category("dairy"), now),
                CheckUpload(product, id, CheckUpload.Target.Product(product), now),
            ),
        )
        val post = server.restRequests().last()
        assertEquals("checks", post.url.encodedPath.substringAfterLast('/'))
        assertTrue(post.headers["Prefer"]!!.contains("resolution=ignore-duplicates"))
        val rows = json(server.bodyOf(post)).jsonArray
        assertEquals(2, rows.size)
        val first = rows[0].jsonObject
        assertEquals("4", first["category_id"]!!.jsonPrimitive.content)
        assertEquals("null", first["product_id"]!!.jsonPrimitive.content)
        assertEquals("null", rows[1].jsonObject["category_id"]!!.jsonPrimitive.content)
        assertEquals(rows[0].jsonObject.keys, rows[1].jsonObject.keys)
    }

    @Test
    fun anUnknownCategoryIsNeverDroppedAndIsReloadedAtMostOnce() = runBlocking<Unit> {
        gateway.ensureSession()
        val check = CheckUpload(id, id, CheckUpload.Target.Category("nouveau"), now)
        expectError<RemoteError.UnknownCategory> { gateway.insertChecks(listOf(check)) }
        val loads = server.restRequests().count { it.url.encodedPath.endsWith("/categories") }
        expectError<RemoteError.UnknownCategory> { gateway.insertChecks(listOf(check)) }
        assertEquals(loads, server.restRequests().count { it.url.encodedPath.endsWith("/categories") })
        assertTrue(server.restRequests().none { it.method.value == "POST" })
    }

    @Test
    fun closingAVisitOnlyTouchesAnOpenOne() = runBlocking<Unit> {
        gateway.ensureSession()
        gateway.closeVisit(id, now)
        val patch = server.restRequests().single()
        assertEquals("PATCH", patch.method.value)
        assertEquals("is.null", patch.url.parameters["ended_at"])
        assertEquals("eq.$id", patch.url.parameters["id"])
        assertEquals("""{"ended_at":"2026-11-08T10:00:00Z"}""", server.bodyOf(patch))
    }

    @Test
    fun visitAccessTellsOpenClosedAndInvisible() = runBlocking<Unit> {
        gateway.ensureSession()
        server.reply("GET visits", Reply(body = """[{"ended_at":null}]"""), Reply(body = """[{"ended_at":"2026-11-08T10:00:00+00:00"}]"""), Reply())
        assertEquals(VisitAccess.Open, gateway.visitAccess(id))
        assertEquals(VisitAccess.Closed, gateway.visitAccess(id))
        assertEquals(VisitAccess.NotVisible, gateway.visitAccess(id))
    }

    // endregion

    // region Lecture et RPC

    @Test
    fun fetchesAreSelectiveAndPaged() = runBlocking<Unit> {
        gateway.ensureSession()
        val row = """{"id":"$id","owner_id":"$id","name":"C","created_at":"2026-11-08T10:00:00+00:00","updated_at":"2026-11-08T10:00:00+00:00"}"""
        server.reply("GET lists", Reply(body = "[$row]"), Reply(body = "[]"))
        val lists = gateway.fetchLists(now)
        assertEquals(1, lists.size)
        val gets = server.restRequests()
        assertEquals(2, gets.size)
        assertEquals("id,name,owner_id,created_at,updated_at".split(",").toSet(), gets[0].url.parameters["select"]!!.split(",").toSet())
        // Curseur avec recouvrement de 5 s.
        assertEquals("gte.2026-11-08T09:59:55Z", gets[0].url.parameters["updated_at"])
        // `id` départage les lignes de même date.
        val order = gets[0].url.parameters["order"].orEmpty()
        assertTrue(order, order.startsWith("updated_at.asc") && order.contains(",id.asc"))
    }

    @Test
    fun rpcCallsUseTheServerParameterNames() = runBlocking<Unit> {
        gateway.ensureSession()
        server.reply("POST rpc/nearby_stores", Reply(body = """[{"id":"$id","name":"S","chain":null,"address":null,"distance_m":12.5,"organic_aisle":true}]"""))
        val stores = gateway.nearbyStores(43.6, 0.58, 3000, 5)
        assertEquals(12.5, stores.single().distanceM, 0.0)
        val nearby = json(server.bodyOf(server.restRequests().last())).jsonObject
        assertEquals(setOf("lat", "lng", "radius_m", "max_results"), nearby.keys)

        server.reply("POST rpc/search_stores", Reply(body = "[]"))
        gateway.searchStores("Lidl", 20)
        assertEquals(setOf("q", "max_results"), json(server.bodyOf(server.restRequests().last())).jsonObject.keys)

        server.reply("POST rpc/resolve_products", Reply(body = """[{"normalized_name":"lait","id":null,"name":null,"category_slug":null}]"""))
        val resolved = gateway.resolveProducts(listOf(ProductResolutionRequest("Lait", "dairy")))
        assertNull(resolved.single().id)
        val items = json(server.bodyOf(server.restRequests().last())).jsonObject["p_items"] as JsonArray
        assertEquals("dairy", (items.single() as JsonObject)["category_slug"]!!.jsonPrimitive.content)

        server.reply("POST rpc/store_graph_snapshot", Reply(body = "null"), Reply(body = """{"none":true}"""), Reply(body = """{"snapshot_version":3}"""))
        assertEquals(GraphSnapshotResponse.Unchanged, gateway.graphSnapshot(id, 3))
        assertEquals(GraphSnapshotResponse.None, gateway.graphSnapshot(id, null))
        assertEquals(GraphSnapshotResponse.Payload("""{"snapshot_version":3}"""), gateway.graphSnapshot(id, null))
        val snapshot = json(server.bodyOf(server.restRequests().last())).jsonObject
        assertEquals(setOf("p_store_id", "p_known_version"), snapshot.keys)
        assertEquals("null", snapshot["p_known_version"]!!.jsonPrimitive.content)
    }

    @Test
    fun resolvingNothingSendsNothing() = runBlocking<Unit> {
        assertEquals(emptyList<Any>(), gateway.resolveProducts(emptyList()))
        assertTrue(server.requests.isEmpty())
    }

    // endregion

    // region Erreurs

    @Test
    fun serverErrorsAreClassified() = runBlocking<Unit> {
        gateway.ensureSession()
        server.reply("PATCH visits", Reply(HttpStatusCode.Forbidden, """{"code":"42501","message":"rls"}"""))
        expectError<RemoteError.Forbidden> { gateway.closeVisit(id, now) }

        server.rest.clear()
        server.reply("PATCH visits", Reply(HttpStatusCode.Forbidden, """{"message":"waf"}"""))
        assertEquals("403", expectError<RemoteError.Server> { gateway.closeVisit(id, now) }.code)

        server.rest.clear()
        server.reply("PATCH visits", Reply(HttpStatusCode.BadGateway, "<html>bad gateway</html>"))
        assertEquals("502", expectError<RemoteError.Server> { gateway.closeVisit(id, now) }.code)

        server.rest.clear()
        server.reply("POST rpc/resolve_products", Reply(HttpStatusCode.NotFound, """{"code":"PGRST202","message":"no function"}"""))
        assertEquals("PGRST202", expectError<RemoteError.Rejected> { gateway.resolveProducts(listOf(ProductResolutionRequest("a", null))) }.code)

        server.rest.clear()
        server.reply("POST visits", Reply(HttpStatusCode.Conflict, """{"code":"23503","message":"fk"}"""))
        expectError<RemoteError.DependencyMissing> {
            gateway.createVisit(fr.parcourses.core.network.dto.VisitInsert(id, id, null, false, now))
        }
    }

    @Test
    fun aNetworkFailureIsClassifiedAndCancellationIsNot() = runBlocking<Unit> {
        gateway.ensureSession()
        server.failWith = IOException("unreachable")
        expectError<RemoteError.Network> { gateway.fetchCategories() }
    }

    // endregion
}
