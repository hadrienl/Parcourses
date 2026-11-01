package fr.parcourses.core.categorizer

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class DictionaryTest {
    private val classifier = CategoryClassifier()
    private val normalizer = classifier.normalizer
    private val rules = CategoryResources.normalizationRules()

    private fun rawCategories() =
        Json
            .parseToJsonElement(
                checkNotNull(javaClass.classLoader.getResource("fr/parcourses/core/categorizer/categories.json"))
                    .readText(),
            ).jsonObject
            .getValue("categories")
            .jsonArray
            .map { it.jsonObject }

    private fun allEntries() = CategoryResources.keywordDictionary().let { it.keywords + it.overrides }

    @Test
    fun dictionaryKeysAreAlreadyNormalized() {
        allEntries().forEach { assertEquals(it.k, normalizer.normalize(it.k)) }
    }

    @Test
    fun dictionaryCategoriesExist() {
        val ids = CategoryResources.categories().map { it.id }.toSet()
        assertTrue(CategoryClassifier.OTHER_CATEGORY_ID in ids)
        allEntries().forEach { assertTrue("${it.k} → ${it.c}", it.c in ids) }
    }

    @Test
    fun categoriesAreSortedByRank() {
        val categories = CategoryResources.categories()
        assertEquals(21, categories.size)
        assertEquals("other", categories.last().id)
        // Le fichier brut, et non la liste déjà triée au chargement.
        val raw = rawCategories()
        val rawRanks = raw.map { it.getValue("rank").jsonPrimitive.long }
        assertEquals(rawRanks.sorted(), rawRanks)
        assertEquals(raw.map { it.getValue("id").jsonPrimitive.content }, categories.map { it.id })
    }

    @Test
    fun categoryIdsAndRanksAreUnique() {
        val categories = CategoryResources.categories()
        assertEquals(categories.size, categories.map { it.id }.toSet().size)
        assertEquals(categories.size, categories.map { it.rank }.toSet().size)
    }

    @Test
    fun categoriesVersionIsExposed() {
        assertTrue(CategoryResources.categoriesVersion() >= 2)
    }

    @Test
    fun organicCategoryReceivesNoKeyword() {
        assertTrue(CategoryResources.categories().any { it.id == ORGANIC_CATEGORY_ID })
        allEntries().forEach { entry ->
            assertNotEquals(entry.k, ORGANIC_CATEGORY_ID, entry.c)
            assertTrue(entry.k, entry.k.split(' ').none { it in CategoryClassifier.ORGANIC_WORDS })
        }
    }

    @Test
    fun organicWordsAreIgnoredByTheSearchButKeptInNormalized() {
        assertEquals(
            Classification("lait bio", "dairy", "lait", MatchKind.Keyword, organic = true),
            classifier.classify("Lait bio"),
        )
        assertEquals(
            Classification("biologique", "other", null, MatchKind.None, organic = true),
            classifier.classify("biologiques"),
        )
    }

    @Test
    fun resourcesAreReadOnlyOnce() {
        assertSame(CategoryResources.categories(), CategoryResources.categories())
        assertSame(CategoryResources.normalizationRules(), CategoryResources.normalizationRules())
        assertSame(CategoryResources.keywordDictionary(), CategoryResources.keywordDictionary())
    }

    @Test
    fun normalizeTextHandlesLigaturesAndPunctuation() {
        assertEquals("oeufs bio creme brulee", normalizer.normalizeText("  Œufs  BIO — Crème brûlée "))
        assertEquals("issmail", normalizer.normalizeText("Ißmaïl"))
        assertEquals("", normalizer.normalizeText("!!!"))
        // Ligature suivie d'un accent combinant : le remplacement reste littéral.
        assertEquals("oeuf", normalizer.normalizeText("œ́uf"))
    }

    @Test
    fun normalizationDoesNotDependOnTheDefaultLocale() {
        val previous = Locale.getDefault()
        try {
            Locale.setDefault(Locale.forLanguageTag("tr-TR"))
            assertEquals("riz ii", normalizer.normalizeText("RIZ II"))
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun emptyLabelFallsBackToOther() {
        listOf("", "!!!", "2 kg de").forEach {
            assertEquals(
                Classification(normalize(it), "other", null, MatchKind.None, organic = false),
                classifier.classify(it),
            )
        }
    }

    @Test
    fun lastDuplicateWins() {
        val dictionary =
            KeywordDictionary(
                version = 1,
                locale = "fr",
                keywords = listOf(KeywordEntry("mot", "a"), KeywordEntry("mot", "b")),
                overrides = listOf(KeywordEntry("force", "c"), KeywordEntry("force", "d")),
            )
        val custom = CategoryClassifier(dictionary, rules)
        assertEquals("b", custom.classify("mot").categoryId)
        assertEquals("d", custom.classify("mot force").categoryId)
    }

    @Test
    fun brandNeverBeatsAProductWord() {
        val dictionary =
            KeywordDictionary(
                version = 1,
                locale = "fr",
                keywords = listOf(KeywordEntry("marque", "a", brand = true), KeywordEntry("mot", "b")),
                overrides = emptyList(),
            )
        val custom = CategoryClassifier(dictionary, rules)
        assertEquals(MatchKind.Keyword, custom.classify("marque mot").match)
        assertEquals(MatchKind.Brand, custom.classify("marque").match)
    }

    private fun normalize(raw: String) = normalizer.normalize(raw)
}
