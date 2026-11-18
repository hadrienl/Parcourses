package fr.parcourses.core.data.attestation

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.time.Instant

/**
 * Vecteurs de `shared/test-vectors/attestation/` relus depuis le dépôt, comme les tests iOS : tous les fichiers sont
 * lus, une fonction inconnue fait échouer le test.
 */
class AttestationDecisionsVectorTest {
    private val dir =
        File(requireNotNull(System.getProperty("parcourses.attestationVectors")) { "parcourses.attestationVectors" })

    private val vectors: List<JsonObject> =
        dir
            .listFiles { f -> f.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }
            .map { Json.parseToJsonElement(it.readText()).jsonObject }

    /** Fonction du contrat → exécution sur l'entrée JSON, sortie dans la forme JSON des vecteurs. */
    private val functions: Map<String, (JsonObject) -> JsonElement> =
        mapOf(
            "shouldAttempt" to { input ->
                JsonPrimitive(
                    AttestationDecisions.shouldAttempt(
                        input.getValue("isAnonymous").jsonPrimitive.boolean,
                        input.optional("state")?.jsonObject?.let(::state),
                        Instant.parse(input.str("now")),
                    ),
                )
            },
            "nextState" to { input ->
                val outcome = AttestationOutcome.entries.single { it.wireName == input.str("outcome") }
                val next = AttestationDecisions.nextState(outcome, Instant.parse(input.str("now")))
                JsonObject(
                    mapOf(
                        "status" to JsonPrimitive(next.status.wireName),
                        "nextAttemptAt" to (next.nextAttemptAt?.let { JsonPrimitive(it.toString()) } ?: JsonNull),
                    ),
                )
            },
            "responseOutcome" to { input ->
                val step = AttestationStep.entries.single { it.wireName == input.str("step") }
                val response =
                    AttestationDecisions.responseOutcome(
                        step,
                        input.getValue("httpStatus").jsonPrimitive.int,
                        input.optional("status")?.jsonPrimitive?.content,
                        input.optional("error")?.jsonPrimitive?.content,
                    )
                when (response) {
                    AttestationResponse.Proceed -> JsonPrimitive("proceed")
                    is AttestationResponse.Outcome -> JsonPrimitive(response.outcome.wireName)
                }
            },
        )

    @Test
    fun everyFunctionOfTheContractHasItsVectorFile() {
        assertTrue("vecteurs introuvables dans $dir", vectors.size >= 3)
        assertEquals(functions.keys, vectors.map { it.str("function") }.toSet())
    }

    @Test
    fun everyVectorMatches() {
        for (vector in vectors) {
            val id = vector.str("id")
            assertEquals("$id : format inconnu", 1, vector.getValue("format_version").jsonPrimitive.int)
            val run = functions[vector.str("function")] ?: error("fonction inconnue : ${vector.str("function")} ($id)")
            val cases = vector.getValue("cases").jsonArray
            assertTrue("$id : aucun cas", cases.isNotEmpty())
            for (case in cases.map { it.jsonObject }) {
                assertEquals(
                    "$id / ${case.str("name")}",
                    case.getValue("expected"),
                    run(case.getValue("input").jsonObject),
                )
            }
        }
    }

    /** Les noms persistés et ceux des vecteurs sont ceux d'iOS. */
    @Test
    fun wireNamesMatchTheContract() {
        assertEquals(
            listOf("pending", "attested", "unsupported"),
            AttestationStatus.entries.map { it.wireName },
        )
        assertEquals(
            listOf("attested", "unsupported", "transient", "notConfigured", "rejected"),
            AttestationOutcome.entries.map { it.wireName },
        )
    }

    private fun state(json: JsonObject): AttestationState =
        AttestationState(
            requireNotNull(AttestationStatus.fromWireName(json.str("status"))),
            json
                .optional("nextAttemptAt")
                ?.jsonPrimitive
                ?.content
                ?.let(Instant::parse),
        )

    private fun JsonObject.optional(key: String): JsonElement? = get(key)?.takeIf { it != JsonNull }

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content
}
