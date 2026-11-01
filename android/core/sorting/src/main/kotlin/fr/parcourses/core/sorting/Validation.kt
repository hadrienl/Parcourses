package fr.parcourses.core.sorting

import fr.parcourses.core.model.SortError
import fr.parcourses.core.model.SortInput
import fr.parcourses.core.model.SortStart

// Validation des entrées, dans le même ordre que `validate` de la référence (et d'iOS).

internal fun validate(input: SortInput) {
    validateCategories(input)
    validateItems(input)
    val start = input.start
    if (start is SortStart.Product) checkId(start.productId, "start.product_id")
    input.previousOrder?.forEach { checkId(it, "previous_order") }
    validateSnapshot(input)
}

private fun validateCategories(input: SortInput) {
    val seenCategories = HashSet<String>()
    for (category in input.categories) {
        checkId(category.id, "category")
        if (!seenCategories.add(category.id)) throw SortError.DuplicateCategory(category.id)
    }
}

private fun validateItems(input: SortInput) {
    val seenItems = HashSet<String>()
    for (item in input.items) {
        checkId(item.id, "item")
        if (!seenItems.add(item.id)) throw SortError.DuplicateItem(item.id)
        item.productId?.let { checkId(it, "item.product_id") }
        item.categoryId?.let { checkId(it, "item.category_id") }
    }
}

private fun validateSnapshot(input: SortInput) {
    val snapshot = input.snapshot ?: return
    for (edge in snapshot.edges) {
        checkId(edge.a, "edge.a")
        checkId(edge.b, "edge.b")
        if (!isValidWeight(edge.weightQ)) throw SortError.InvalidWeight("${edge.a}-${edge.b}", edge.weightQ)
    }
    for (entry in snapshot.entries) {
        checkId(entry.productId, "entry.product_id")
        if (!isValidWeight(entry.weightQ)) throw SortError.InvalidWeight("entry ${entry.productId}", entry.weightQ)
    }
}

/**
 * Poids valide : positif ou nul, au plus `2^53 - 1` (`Number.isSafeInteger` de la référence).
 * Cette borne évite aussi le débordement de `1000 + weightQ` dans `edgeCost`.
 */
private fun isValidWeight(weightQ: Long): Boolean = weightQ in 0..MAX_SAFE_WEIGHT

private const val MAX_SAFE_WEIGHT = (1L shl 53) - 1

private fun checkId(
    id: String,
    field: String,
) {
    if (!isValidId(id)) throw SortError.InvalidId(field, id)
}
