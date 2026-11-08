package fr.parcourses.feature.lists

import fr.parcourses.core.database.entity.ListItemEntity
import org.junit.Assert.assertEquals
import org.junit.Test
import kotlin.time.Instant

class ItemSuggestionIndexTest {
    private val at = Instant.fromEpochSeconds(100)

    private fun item(
        label: String,
        name: String,
        id: String,
    ) = ListItemEntity(
        id = id,
        listId = "l",
        label = label,
        normalizedName = name,
        categoryId = "other",
        position = 0,
        updatedAt = at,
    )

    @Test
    fun theOrderIgnoresTheOrderOfTheHistory() {
        val a = item("Lait", "lait", "a")
        val b = item("Laitue", "laitue", "b")
        val first = ItemSuggestionIndex(listOf(a, b), emptyList()) { it }.suggestions(listOf("lait"), emptySet())
        val second = ItemSuggestionIndex(listOf(b, a), emptyList()) { it }.suggestions(listOf("lait"), emptySet())
        assertEquals(first, second)
        assertEquals(listOf("lait", "laitue"), first.map { it.id })
    }

    @Test
    fun theMostUsedThenTheMostRecentComesFirstAndTheLatestLabelWins() {
        val history =
            listOf(
                item("riz", "riz", "1"),
                item("Riz basmati", "riz", "2").copy(updatedAt = at + kotlin.time.Duration.parse("1m")),
                item("rillettes", "rillette", "3"),
            )
        val result = ItemSuggestionIndex(history, emptyList()) { it }.suggestions(listOf("ri"), emptySet())
        assertEquals(listOf("riz", "rillette"), result.map { it.normalizedName })
        assertEquals("Riz basmati", result.first().label)
        assertEquals(2, result.first().useCount)
    }

    @Test
    fun aWordInTheMiddleMatchesAndExcludedNamesAreSkipped() {
        val history = listOf(item("pommes de terre", "pomme terre", "1"), item("terrine", "terrine", "2"))
        val index = ItemSuggestionIndex(history, emptyList()) { it }
        assertEquals(
            listOf("pomme terre", "terrine"),
            index.suggestions(listOf("terre", "terr"), emptySet()).map { it.id },
        )
        assertEquals(listOf("terrine"), index.suggestions(listOf("terre", "terr"), setOf("pomme terre")).map { it.id })
        assertEquals(emptyList<ItemSuggestion>(), index.suggestions(emptyList(), emptySet()))
    }

    @Test
    fun theLimitIsFive() {
        val history = (1..9).map { item("pomme $it", "pomme $it", "$it") }
        assertEquals(5, ItemSuggestionIndex(history, emptyList()) { it }.suggestions(listOf("pomme"), emptySet()).size)
    }
}
