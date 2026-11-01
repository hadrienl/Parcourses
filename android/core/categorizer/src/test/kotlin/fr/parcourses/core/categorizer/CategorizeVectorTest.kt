package fr.parcourses.core.categorizer

import kotlinx.serialization.json.Json
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

// Vecteurs de shared/test-vectors/categorize/, lus directement dans le dépôt, sans copie.
private val vectorDir =
    File(requireNotNull(System.getProperty("parcourses.categorizeVectors")) { "parcourses.categorizeVectors absent" })

private fun vectorFiles(): List<File> =
    vectorDir
        .listFiles()
        .orEmpty()
        .filter { it.isFile }
        .sortedBy { it.name }

private fun parse(file: File): JsonObject = Json.parseToJsonElement(file.readText()).jsonObject

class CategorizeVectorTest {
    private val classifier = CategoryClassifier()

    // Garde-fou : tous les fichiers du dossier sont des vecteurs lus, aucun n'est ignoré.
    @Test
    fun everyFileInTheDirectoryIsAVector() {
        val files = vectorFiles()
        assertTrue("vecteurs introuvables dans $vectorDir", files.size >= 10)
        files.forEach { file ->
            assertEquals("json", file.extension)
            val vector = parse(file)
            assertEquals(file.name, 1, vector.getValue("format_version").jsonPrimitive.int)
            assertTrue(file.name, vector.getValue("cases").jsonArray.isNotEmpty())
        }
    }

    @Test
    fun idsAreUniqueAndMatchFileNames() {
        val files = vectorFiles()
        val ids = files.map { parse(it).getValue("id").jsonPrimitive.content }
        assertEquals(ids.size, ids.toSet().size)
        assertEquals(files.map { it.nameWithoutExtension }, ids)
    }

    @Test
    fun everyCaseMatchesTheReference() {
        val failures =
            vectorFiles().flatMap { file ->
                parse(file).getValue("cases").jsonArray.mapNotNull { element ->
                    val case = element.jsonObject
                    val input = case.getValue("input").jsonPrimitive.content
                    val want = expected(case.getValue("expected").jsonObject)
                    val got = classifier.classify(input)
                    if (got == want) null else "${file.name} « $input » : attendu $want, obtenu $got"
                }
            }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun expected(o: JsonObject) =
        Classification(
            normalized = o.getValue("normalized").jsonPrimitive.content,
            categoryId = o.getValue("category_id").jsonPrimitive.content,
            matchedKeyword =
                o
                    .getValue("matched_keyword")
                    .takeUnless { it is JsonNull }
                    ?.jsonPrimitive
                    ?.content,
            match = MatchKind.entries.single { it.wireName == o.getValue("match").jsonPrimitive.content },
            organic = o.getValue("organic").jsonPrimitive.boolean,
        )
}
