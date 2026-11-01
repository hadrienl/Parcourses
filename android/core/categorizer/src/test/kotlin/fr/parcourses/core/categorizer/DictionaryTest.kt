package fr.parcourses.core.categorizer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class DictionaryTest {
    private val classifier = CategoryClassifier()
    private val normalizer = classifier.normalizer
    private val rules = CategoryResources.normalizationRules()

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
        assertEquals(20, categories.size)
        assertEquals("other", categories.last().id)
        assertEquals(categories.map { it.rank }.sorted(), categories.map { it.rank })
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
                Classification(normalize(it), "other", null, MatchKind.None),
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
