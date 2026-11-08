package fr.parcourses.core.network

import fr.parcourses.core.network.session.SecureState
import fr.parcourses.core.network.session.SecureStateStore
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.content.TextContent
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.headersOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.Base64

/** Stockage de session en mémoire, partageable entre deux « lancements » de l'app. */
class MemorySecureStateStore(
    initial: SecureState = SecureState(),
) : SecureStateStore {
    private val lock = Mutex()
    private var state = initial

    override suspend fun read(): SecureState = lock.withLock { state }

    override suspend fun update(transform: (SecureState) -> SecureState) {
        lock.withLock { state = transform(state) }
    }
}

/** Faux serveur Supabase : enregistre les requêtes et répond par un gestionnaire par chemin. */
class FakeSupabase {
    val requests = mutableListOf<HttpRequestData>()
    var userId = "aaaaaaaa-0000-4000-8000-000000000001"
    var failWith: Throwable? = null

    /** Réponses REST, par `méthode chemin`. Absent : `200 []`. */
    val rest = mutableMapOf<String, MutableList<Reply>>()

    class Reply(
        val status: HttpStatusCode = HttpStatusCode.OK,
        val body: String = "[]",
        val headers: Map<String, String> = emptyMap(),
    )

    fun reply(
        route: String,
        vararg replies: Reply,
    ) {
        rest.getOrPut(route) { mutableListOf() }.addAll(replies)
    }

    val signUps get() = requests.count { it.url.encodedPath.endsWith("/auth/v1/signup") }

    fun restRequests() = requests.filter { it.url.encodedPath.startsWith("/rest/v1/") }

    fun bodyOf(request: HttpRequestData): String = (request.body as TextContent).text

    val engine =
        MockEngine { request ->
            requests += request
            failWith?.let { throw it }
            val path = request.url.encodedPath
            when {
                path.endsWith("/auth/v1/signup") -> {
                    json(sessionJson())
                }

                path.endsWith("/auth/v1/user") -> {
                    json("""{"id":"$userId","aud":"authenticated"}""")
                }

                path.startsWith("/rest/v1/") -> {
                    val key = "${request.method.value} ${path.removePrefix("/rest/v1/")}"
                    val queue = rest[key]
                    val reply =
                        if (queue.isNullOrEmpty()) {
                            Reply()
                        } else if (queue.size >
                            1
                        ) {
                            queue.removeAt(0)
                        } else {
                            queue.first()
                        }
                    respond(
                        reply.body,
                        reply.status,
                        headersOf(
                            HttpHeaders.ContentType to listOf("application/json"),
                            *reply.headers.map { (k, v) -> k to listOf(v) }.toTypedArray(),
                        ),
                    )
                }

                else -> {
                    respond("{}", HttpStatusCode.NotFound)
                }
            }
        }

    private fun MockRequestHandleScope.json(body: String): HttpResponseData =
        respond(body, HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, "application/json"))

    private fun sessionJson(): String {
        val exp = System.currentTimeMillis() / 1000 + 3600
        return """{"access_token":"${jwt(exp)}","token_type":"bearer","expires_in":3600,"expires_at":$exp,""" +
            """"refresh_token":"refresh-1","user":{"id":"$userId","aud":"authenticated","role":"authenticated","is_anonymous":true}}"""
    }

    private fun jwt(exp: Long): String {
        val encoder = Base64.getUrlEncoder().withoutPadding()

        fun part(s: String) = encoder.encodeToString(s.toByteArray())
        return part("""{"alg":"HS256","typ":"JWT"}""") + "." +
            part("""{"sub":"$userId","exp":$exp,"role":"authenticated"}""") +
            ".sig"
    }
}

/** Gateway branché sur un [FakeSupabase], avec le cycle de vie du processus désactivé (pas d'Android ici). */
class GatewayHarness(
    val server: FakeSupabase = FakeSupabase(),
    val store: SecureStateStore = MemorySecureStateStore(),
) {
    private val scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob())
    val config = SupabaseConfig.create("http://127.0.0.1:56321", "publishable-key")!!
    val gateway =
        SupabaseGateway(
            createSupabaseClient(config, store, server.engine, Dispatchers.Unconfined, lifecycleCallbacks = false),
            store,
        )

    fun close() = scope.cancel()
}
