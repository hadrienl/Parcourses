package fr.parcourses.core.data.sync

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.time.Instant

/**
 * Vecteurs de `shared/test-vectors/sync/` relus depuis le dépôt, comme `shared/reference/sync.test.ts` et les tests
 * iOS : tous les fichiers sont lus, une fonction inconnue fait échouer le test.
 */
class SyncDecisionsVectorTest {
    private val dir = File(requireNotNull(System.getProperty("parcourses.syncVectors")) { "parcourses.syncVectors" })

    private val vectors: List<JsonObject> =
        dir
            .listFiles { f -> f.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }
            .map { Json.parseToJsonElement(it.readText()).jsonObject }

    /** Fonction du contrat → exécution sur l'entrée JSON, sortie dans la forme JSON des vecteurs. */
    private val functions: Map<String, (JsonObject) -> JsonElement> =
        mapOf(
            "itemSaveRequest" to { input ->
                when (val r = SyncDecisions.itemSaveRequest(input.bool("isOnServer"), input.strings("changedFields"))) {
                    ItemSaveRequest.Insert -> {
                        buildJsonObject { put("kind", "insert") }
                    }

                    ItemSaveRequest.None -> {
                        buildJsonObject { put("kind", "none") }
                    }

                    is ItemSaveRequest.Patch -> {
                        JsonObject(
                            mapOf(
                                "kind" to JsonPrimitive("patch"),
                                "fields" to r.fields.json(),
                            ),
                        )
                    }
                }
            },
            "mergeChangedFields" to { input ->
                val pending = input["pending"]?.takeIf { it != JsonNull }?.jsonArray?.map { it.jsonPrimitive.content }
                SyncDecisions.mergeChangedFields(pending, input.strings("new")).json()
            },
            "zeroRowOutcome" to
                { input -> JsonPrimitive(SyncDecisions.zeroRowOutcome(input.bool("tombstoned")).wireName) },
            "insertRefusedOutcome" to { input ->
                JsonPrimitive(
                    SyncDecisions.insertRefusedOutcome(input.bool("listSynced"), input.bool("listOwnedByMe")).wireName,
                )
            },
            "reconcileLists" to { input ->
                val local =
                    input.getValue("local").jsonArray.map {
                        LocalListState(it.jsonObject.str("id"), it.jsonObject.bool("syncedOnce"))
                    }
                val plan = SyncDecisions.reconcileLists(local, input.strings("accessible"))
                JsonObject(mapOf("remove" to plan.remove.json(), "fetchFully" to plan.fetchFully.json()))
            },
            "applyTombstones" to { input ->
                val doomed = SyncDecisions.applyTombstones(input.strings("localItems"), input.strings("tombstones"))
                JsonObject(mapOf("delete" to doomed.json()))
            },
            "tombstonePullMode" to { input ->
                val cursor =
                    input["cursor"]
                        ?.takeIf { it != JsonNull }
                        ?.jsonPrimitive
                        ?.content
                        ?.let(Instant::parse)
                JsonPrimitive(SyncDecisions.tombstonePullMode(cursor, Instant.parse(input.str("now"))).wireName)
            },
            "rekeyPlan" to { input ->
                val list = input.getValue("list").jsonObject
                val state =
                    RekeyListState(
                        ownerId = list["ownerId"]?.takeIf { it != JsonNull }?.jsonPrimitive?.content,
                        deleted = list.bool("deleted"),
                        itemCount = list.getValue("itemCount").jsonPrimitive.int,
                        createdAt = Instant.parse(list.str("createdAt")),
                        updatedAt = Instant.parse(list.str("updatedAt")),
                    )
                JsonPrimitive(SyncDecisions.rekeyPlan(input.str("previousAccountId"), state).wireName)
            },
            "sessionLossAction" to { input ->
                val kind = requireNotNull(AccountKind.fromWireName(input.str("accountKind")))
                JsonPrimitive(SyncDecisions.sessionLossAction(kind).wireName)
            },
            "linkEmailNextStep" to { input ->
                val code = input["errorCode"]?.takeIf { it != JsonNull }?.jsonPrimitive?.content
                JsonPrimitive(
                    SyncDecisions.linkEmailNextStep(input.getValue("status").jsonPrimitive.int, code).wireName,
                )
            },
        )

    @Test
    fun everyFunctionOfTheContractHasItsVectorFile() {
        assertTrue("vecteurs introuvables dans $dir", vectors.size >= 10)
        assertEquals(functions.keys, vectors.map { it.str("function") }.toSet())
    }

    @Test
    fun everyVectorMatches() {
        for (vector in vectors) {
            val id = vector.str("id")
            assertEquals(id, 1, vector.getValue("format_version").jsonPrimitive.int)
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

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content

    private fun JsonObject.bool(key: String) = getValue(key).jsonPrimitive.boolean

    private fun JsonObject.strings(key: String) = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    private fun List<String>.json() = JsonArray(map(::JsonPrimitive))
}
