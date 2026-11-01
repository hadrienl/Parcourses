package fr.parcourses.core.categorizer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Vecteurs de shared/test-vectors/effective-category/, lus directement dans le dépôt, sans copie.
class EffectiveCategoryVectorTest {
    private val classifier = CategoryClassifier()
    private val dir =
        File(
            requireNotNull(System.getProperty("parcourses.effectiveCategoryVectors")) {
                "parcourses.effectiveCategoryVectors absent"
            },
        )

    private fun files() =
        dir
            .listFiles()
            .orEmpty()
            .filter { it.isFile }
            .sortedBy { it.name }

    private fun parse(file: File) = Json.parseToJsonElement(file.readText()).jsonObject

    private fun cases(file: File) = parse(file).getValue("cases").jsonArray.map { it.jsonObject }

    // Garde-fou : tous les fichiers du dossier sont des vecteurs lus, aucun n'est ignoré.
    @Test
    fun everyFileInTheDirectoryIsAVector() {
        val files = files()
        assertTrue("vecteurs introuvables dans $dir", files.size >= 2)
        files.forEach { file ->
            assertEquals("json", file.extension)
            assertEquals(file.nameWithoutExtension, parse(file).getValue("id").jsonPrimitive.content)
            assertTrue(file.name, cases(file).isNotEmpty())
        }
    }

    @Test
    fun everyCaseMatchesTheReference() {
        val failures = files().flatMap { file -> cases(file).mapNotNull { check(file.name, it) } }
        assertTrue(failures.joinToString("\n"), failures.isEmpty())
    }

    private fun check(
        fileName: String,
        case: JsonObject,
    ): String? {
        val input = case.getValue("input").jsonObject
        val categoryId = input.getValue("category_id").jsonPrimitive.content
        val organic = input.getValue("organic").jsonPrimitive.boolean
        val aisle = input.getValue("store_organic_aisle").jsonPrimitive.boolean
        val want =
            case
                .getValue("expected")
                .jsonObject
                .getValue("effective_category")
                .jsonPrimitive.content
        val got = effectiveCategory(categoryId, organic, aisle)
        // Label facultatif : le classifieur doit en déduire la catégorie et le drapeau bio d'entrée.
        val classified = case["label"]?.jsonPrimitive?.content?.let(classifier::classify)
        val labelOk = classified == null || (classified.categoryId == categoryId && classified.organic == organic)
        return if (got == want && labelOk) null else "$fileName $case : obtenu $got, classifieur $classified"
    }
}
