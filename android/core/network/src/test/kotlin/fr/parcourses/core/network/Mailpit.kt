package fr.parcourses.core.network

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.net.HttpURLConnection
import java.net.URI
import java.net.URLEncoder
import java.time.Instant
import java.util.UUID

/**
 * Boîte de test de la pile Supabase locale (Mailpit, `scripts/integration-test.sh`) : le code à 6 chiffres d'un
 * e-mail reçu, comme `supabase/tests/e2e/stack.ts`. Jamais ailleurs que sur 127.0.0.1.
 */
internal object Mailpit {
    /** URL donnée par le script (`supabase status`), jamais ailleurs que sur 127.0.0.1. */
    private val base: String? = System.getenv("PARCOURSES_IT_MAILPIT")?.takeIf { URI(it).host == "127.0.0.1" }

    val isConfigured: Boolean get() = base != null

    /** Adresse unique par test : Mailpit garde tous les messages de la pile. */
    fun address(tag: String): String = "it-android-87-$tag-${UUID.randomUUID().toString().take(8)}@example.com"

    /** Code du dernier e-mail reçu par [to] après [since] (attente de 10 s au plus). */
    fun code(
        to: String,
        since: Instant,
    ): String {
        repeat(ATTEMPTS) {
            val query = URLEncoder.encode("to:\"$to\"", Charsets.UTF_8)
            val messages = get("/api/v1/search?query=$query").jsonObject["messages"]
            val fresh =
                (messages as? JsonArray)
                    ?.map { it.jsonObject }
                    ?.filter { Instant.parse(it["Created"]!!.jsonPrimitive.content) >= since.minusSeconds(1) }
                    ?.maxByOrNull { it["Created"]!!.jsonPrimitive.content }
            if (fresh != null) {
                val text = get("/api/v1/message/${fresh["ID"]!!.jsonPrimitive.content}").jsonObject["Text"]
                val code = CODE.find(text!!.jsonPrimitive.content)?.value
                return checkNotNull(code) { "aucun code dans l'e-mail" }
            }
            Thread.sleep(DELAY_MS)
        }
        error("aucun e-mail reçu par $to")
    }

    private fun get(path: String) =
        (URI("${checkNotNull(base)}$path").toURL().openConnection() as HttpURLConnection).run {
            try {
                Json.parseToJsonElement(inputStream.bufferedReader().readText())
            } finally {
                disconnect()
            }
        }

    private val CODE = Regex("\\b\\d{6}\\b")
    private const val ATTEMPTS = 50
    private const val DELAY_MS = 200L
}
