package fr.parcourses.core.data.sharing

import fr.parcourses.core.model.ListRole
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
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

/**
 * Vecteurs de `shared/test-vectors/sharing/` relus depuis le dépôt, comme `shared/reference/sharing.test.ts` et les
 * tests iOS : tous les fichiers sont lus, une fonction inconnue fait échouer le test.
 */
class SharingDecisionsVectorTest {
    private val dir =
        File(requireNotNull(System.getProperty("parcourses.sharingVectors")) { "parcourses.sharingVectors" })

    private val vectors: List<JsonObject> =
        dir
            .listFiles { f -> f.extension == "json" }
            .orEmpty()
            .sortedBy { it.name }
            .map { Json.parseToJsonElement(it.readText()).jsonObject }

    /** Fonction du contrat → exécution sur l'entrée JSON, sortie dans la forme JSON des vecteurs. */
    private val functions: Map<String, (JsonObject) -> JsonElement> =
        mapOf(
            "parseInvitationLink" to { input ->
                JsonPrimitive(SharingDecisions.parseInvitationLink(input.str("url"), input.optional("httpsHost")))
            },
            "roleCapabilities" to { input ->
                val role = requireNotNull(ListRole.fromWire(input.str("role"))) { input.str("role") }
                val c = SharingDecisions.roleCapabilities(role)
                JsonObject(
                    mapOf(
                        "canEditItems" to JsonPrimitive(c.canEditItems),
                        "canShop" to JsonPrimitive(c.canShop),
                        "canShare" to JsonPrimitive(c.canShare),
                        "canManageMembers" to JsonPrimitive(c.canManageMembers),
                        "canLeave" to JsonPrimitive(c.canLeave),
                        "canRenameList" to JsonPrimitive(c.canRenameList),
                        "canDeleteList" to JsonPrimitive(c.canDeleteList),
                    ),
                )
            },
            "inviteErrorKind" to { input ->
                JsonPrimitive(SharingDecisions.inviteErrorKind(input.optional("error")).wireName)
            },
            "invitationCardState" to { input ->
                JsonPrimitive(
                    SharingDecisions.invitationCardState(input.str("status"), input.bool("emailMatches")).wireName,
                )
            },
            "acceptOutcome" to { input -> JsonPrimitive(SharingDecisions.acceptOutcome(input.str("status")).wireName) },
            "signalActions" to { input ->
                val actions = SharingDecisions.signalActions(input.str("kind"), input.bool("sharingSheetOpen"))
                JsonArray(actions.map { JsonPrimitive(it.wireName) })
            },
            "memberInitial" to { input ->
                JsonPrimitive(SharingDecisions.memberInitial(input.optional("displayName")))
            },
            "itemAuthorMark" to { input ->
                val members =
                    input.getValue("members").jsonArray.map {
                        SharingMember(it.jsonObject.str("userId"), it.jsonObject.optional("displayName"))
                    }
                JsonPrimitive(
                    SharingDecisions.itemAuthorMark(
                        updatedBy = input.optional("updatedBy"),
                        me = input.str("me"),
                        shared = input.bool("shared"),
                        members = members,
                    ),
                )
            },
        )

    @Test
    fun everyFunctionOfTheContractHasItsVectorFile() {
        assertTrue("vecteurs introuvables dans $dir", vectors.size >= functions.size)
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

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content

    private fun JsonObject.optional(key: String): String? = get(key)?.takeIf { it != JsonNull }?.jsonPrimitive?.content

    private fun JsonObject.bool(key: String) = getValue(key).jsonPrimitive.boolean
}
