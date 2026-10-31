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
    fun rejectsNegativeWeights() {
        assertThrows(SortError.NegativeWeight::class.java) {
            sortItems(base.copy(snapshot = SortSnapshot(900, emptyList(), listOf(SnapshotEdge("a", "b", -1)))))
        }
        assertThrows(SortError.NegativeWeight::class.java) {
            sortItems(base.copy(snapshot = SortSnapshot(900, listOf(SnapshotEntry("a", -1)), emptyList())))
        }
    }

    @Test
    fun comparesBytesUnsigned() {
        // « é » (0xC3 0xA9) passe après « z » (0x7A) en octets UTF-8 non signés.
        assert(compareBytes("é", "z") > 0)
        assert(compareBytes("ab", "abc") < 0)
    }
}
