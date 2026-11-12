package fr.parcourses.core.sorting

import fr.parcourses.core.model.SnapshotEdge
import fr.parcourses.core.model.SortError
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortSnapshot
import fr.parcourses.core.model.SortStart
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

// #30 : le magasin préparé accélère le tri sans jamais en changer le résultat.
class PreparedStoreTest {
    // Une visite entière avec le même magasin préparé : chaque recalcul réutilise les distances
    // déjà calculées et doit rester identique au tri sans précalcul.
    @Test
    fun visitWithOneStoreMatchesPlainSort() {
        val inputs =
            listOf(
                SortVectors.byId("031-large-80-items-partial-graph").input,
                SortVectors.byId("032-large-80-items-recompute-with-previous").input,
                SyntheticStore.input(products = SyntheticStore.STORE_PRODUCTS),
            )
        for (input in inputs) assertVisitMatches(input)
    }

    // Le second tri identique ne calcule aucune nouvelle ligne : le cache sert bien.
    @Test
    fun distancesAreComputedOnce() {
        val input = SyntheticStore.input(products = SyntheticStore.STORE_PRODUCTS)
        val prepared = PreparedStore(requireNotNull(input.snapshot), input.params)
        assertEquals(0, prepared.cachedSources)
        val first = sortItems(input, prepared)
        // L'entrée et les 80 produits de la liste.
        assertEquals(SyntheticStore.ITEMS + 1, prepared.cachedSources)
        assertEquals(first, sortItems(input, prepared))
        assertEquals(SyntheticStore.ITEMS + 1, prepared.cachedSources)
    }

    @Test
    fun storeOfAnotherSnapshotIsIgnored() {
        val input = SortVectors.byId("031-large-80-items-partial-graph").input
        val other = SortVectors.byId("033-complete-graph-40-items").input
        val prepared = PreparedStore(requireNotNull(other.snapshot), other.params)
        assertFalse(prepared.matches(input))
        assertEquals(sortItems(input), sortItems(input, prepared))
    }

    @Test
    fun storeWithOtherParamsIsIgnored() {
        val input = SortVectors.byId("031-large-80-items-partial-graph").input
        val prepared = PreparedStore(requireNotNull(input.snapshot), input.params.copy(costScale = 7))
        assertFalse(prepared.matches(input))
        assertTrue(prepared.matches(input.copy(params = prepared.params)))
        assertEquals(sortItems(input), sortItems(input, prepared))
    }

    @Test
    fun invalidSnapshotIsRejectedLikeSortItems() {
        val snapshot = SortSnapshot(900, emptyList(), listOf(SnapshotEdge("p-1", "P-2", 1)))
        val input = SyntheticStore.input(products = SyntheticStore.ITEMS).copy(snapshot = snapshot)
        val direct = assertThrows(SortError.InvalidId::class.java) { sortItems(input) }
        val prepared = assertThrows(SortError.InvalidId::class.java) { PreparedStore(snapshot, input.params) }
        assertEquals(direct.message, prepared.message)
    }

    // Le reste de l'entrée est toujours validé, même quand l'instantané l'a été à la préparation.
    @Test
    fun requestIsStillValidated() {
        val input = SyntheticStore.input(products = SyntheticStore.ITEMS)
        val prepared = PreparedStore(requireNotNull(input.snapshot), input.params)
        val invalid = input.copy(previousOrder = listOf("I-1"))
        assertThrows(SortError.InvalidId::class.java) { sortItems(invalid, prepared) }
    }

    private fun assertVisitMatches(input: SortInput) {
        val prepared = PreparedStore(requireNotNull(input.snapshot), input.params)
        assertTrue(prepared.matches(input))
        var current = input
        while (current.items.isNotEmpty()) {
            val plain = sortItems(current)
            assertEquals(plain, sortItems(current, prepared))
            // On coche le premier article : départ depuis son produit, ordre précédent conservé.
            val checked = current.items.first { it.id == plain.order.first() }
            current =
                current.copy(
                    items = current.items - checked,
                    start = checked.productId?.let { SortStart.Product(it) } ?: current.start,
                    previousOrder = plain.order.drop(1),
                )
        }
    }
}
