package fr.parcourses.core.categorizer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Vecteurs de shared/test-vectors/quantity/ (#110), lus directement dans le dépôt, sans copie.
class ItemQuantityVectorTest {
    private val dir =
        File(
            requireNotNull(System.getProperty("parcourses.quantityVectors")) { "parcourses.quantityVectors absent" },
        )

    private fun files() =
        dir
            .listFiles()
            .orEmpty()
            .filter { it.isFile && it.extension == "json" }
            .sortedBy { it.name }

    private fun parse(file: File) = Json.parseToJsonElement(file.readText()).jsonObject

    private fun cases(file: File) = parse(file).getValue("cases").jsonArray.map { it.jsonObject }

    // Garde-fou : tous les vecteurs du dossier sont lus, aucun n'est ignoré ; seul le README les accompagne.
    @Test
    fun everyFileInTheDirectoryIsAVector() {
        val files = files()
        assertTrue("vecteurs introuvables dans $dir", files.size >= KNOWN_FUNCTIONS.size)
        val others =
            dir
                .listFiles()
                .orEmpty()
                .filter { it.isFile && it.extension != "json" }
                .map { it.name }
        assertEquals(listOf("README.md"), others)
        files.forEach { file ->
            val vector = parse(file)
            assertEquals(file.nameWithoutExtension, vector.getValue("id").jsonPrimitive.content)
            val function = vector.getValue("function").jsonPrimitive.content
            assertTrue("${file.name} : fonction inconnue $function", function in KNOWN_FUNCTIONS)
            assertTrue(file.name, cases(file).isNotEmpty())
        }
    }

    @Test
    fun everyCaseMatchesTheReference() {
        val failures =
            files().flatMap { file ->
                val function = parse(file).getValue("function").jsonPrimitive.content
                cases(file).mapNotNull { check(file.name, function, it) }
            }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun check(
        fileName: String,
        function: String,
        case: JsonObject,
    ): String? {
        val input = case.getValue("input").jsonObject
        val want = case.getValue("expected").stringOrNull()
        val got =
            when (function) {
                "stepQuantity" -> {
                    ItemQuantity.stepQuantity(input.string("quantity"), input.getValue("delta").jsonPrimitive.int)
                }

                "setQuantityUnit" -> {
                    val unit = requireNotNull(QuantityUnit.fromSymbol(input.getValue("unit").jsonPrimitive.content))
                    ItemQuantity.setQuantityUnit(input.string("quantity"), unit)
                }

                "quantityUnit" -> {
                    ItemQuantity.quantityUnit(input.string("quantity"))?.symbol
                }

                "quantityInput" -> {
                    ItemQuantity.quantityInput(input.getValue("text").jsonPrimitive.content)
                }

                "entryMergeTarget" -> {
                    entryMergeTarget(input)
                }

                else -> {
                    return "$fileName : fonction inconnue $function"
                }
            }
        val name = case.getValue("name").jsonPrimitive.content
        return if (got == want) null else "$fileName « $name » : attendu $want, obtenu $got"
    }

    private fun entryMergeTarget(input: JsonObject): String? {
        val entry = input.getValue("entry").jsonObject
        val items =
            input.getValue("items").jsonArray.map {
                val item = it.jsonObject
                QuantityItem(
                    id = item.getValue("id").jsonPrimitive.content,
                    normalizedName = item.getValue("normalizedName").jsonPrimitive.content,
                    checked = item.getValue("checked").jsonPrimitive.boolean,
                )
            }
        return ItemQuantity.entryMergeTarget(
            QuantityEntry(entry.getValue("normalizedName").jsonPrimitive.content, entry.string("quantity")),
            items,
        )
    }

    private fun JsonObject.string(key: String): String? = getValue(key).stringOrNull()

    private fun JsonElement.stringOrNull(): String? = if (this is JsonNull) null else jsonPrimitive.content

    private companion object {
        val KNOWN_FUNCTIONS =
            setOf("stepQuantity", "setQuantityUnit", "quantityUnit", "quantityInput", "entryMergeTarget")
    }
}
