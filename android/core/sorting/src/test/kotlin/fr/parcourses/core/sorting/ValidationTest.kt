package fr.parcourses.core.sorting

import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SnapshotEntry
import fr.parcourses.core.model.SortCategory
import fr.parcourses.core.model.SortError
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortItem
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.model.SortStart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class ValidationTest {
    private val base =
        SortInput(
            categories = listOf(SortCategory("dairy", 10)),
            snapshot = SortSnapshot(900, emptyList(), emptyList()),
            items = listOf(SortItem("i-1", "p-milk", "dairy", "lait")),
            start = SortStart.Entry,
            previousOrder = null,
        )

    @Test
    fun acceptsValidInput() {
        assertEquals(listOf("i-1"), sortItems(base).order)
    }

    @Test
    fun rejectsUppercaseOrNonAsciiIds() {
        for (bad in listOf("I-1", "é", "", "a_b", "a b")) {
            val e =
                assertThrows(SortError.InvalidId::class.java) {
                    sortItems(base.copy(items = listOf(SortItem(bad, null, null, "x"))))
                }
            assertEquals("item", e.field)
        }
        assertThrows(SortError.InvalidId::class.java) { sortItems(base.copy(start = SortStart.Product("P"))) }
        assertThrows(SortError.InvalidId::class.java) { sortItems(base.copy(previousOrder = listOf("X"))) }
        assertThrows(SortError.InvalidId::class.java) {
            sortItems(base.copy(categories = listOf(SortCategory("Dairy", 1))))
        }
    }

    @Test
    fun rejectsDuplicates() {
        assertThrows(SortError.DuplicateItem::class.java) { sortItems(base.copy(items = base.items + base.items)) }
        assertThrows(SortError.DuplicateCategory::class.java) {
            sortItems(base.copy(categories = base.categories + base.categories))
        }
    }

    @Test
    fun rejectsWeightsOutsideSafeRange() {
        for (bad in listOf(-1L, MAX_SAFE + 1, Long.MAX_VALUE)) {
            assertThrows(SortError.InvalidWeight::class.java) { sortItems(withEdgeWeight(bad)) }
            assertThrows(SortError.InvalidWeight::class.java) { sortItems(withEntryWeight(bad)) }
        }
    }

    @Test
    fun acceptsLargestSafeWeight() {
        assertEquals(listOf("i-1"), sortItems(withEdgeWeight(MAX_SAFE)).order)
        assertEquals(listOf("i-1"), sortItems(withEntryWeight(MAX_SAFE)).order)
    }

    private fun withEdgeWeight(w: Long) =
        base.copy(snapshot = SortSnapshot(900, emptyList(), listOf(SnapshotEdge("a", "b", w))))

    private fun withEntryWeight(w: Long) =
        base.copy(snapshot = SortSnapshot(900, listOf(SnapshotEntry("a", w)), emptyList()))

    @Test
    fun comparesBytesUnsigned() {
        // « é » (0xC3 0xA9) passe après « z » (0x7A) en octets UTF-8 non signés.
        assert(compareBytes("é", "z") > 0)
        assert(compareBytes("ab", "abc") < 0)
        // Formes NFC et NFD : canoniquement équivalentes, mais octets différents.
        assert(compareBytes("\u00e9", "e\u0301") > 0)
        assertEquals(0, compareBytes("abc", "abc"))
        // Hors BMP : 0xF0 > 0xEF en UTF-8, alors qu'un surrogate UTF-16 passerait avant U+FFFF.
        assert(compareBytes("\uD83C\uDF4E", "\uFFFF") > 0)
    }

    @Test
    fun fallbackOrdersNonBmpNamesByUtf8Bytes() {
        val items =
            listOf(
                SortItem("i-1", null, "dairy", "\uD83C\uDF4E"),
                SortItem("i-2", null, "dairy", "\uFFFF"),
            )
        assertEquals(listOf("i-2", "i-1"), sortItems(base.copy(snapshot = null, items = items)).order)
    }

    private companion object {
        const val MAX_SAFE = (1L shl 53) - 1
    }
}
