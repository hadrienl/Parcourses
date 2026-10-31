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
        if (edge.weightQ < 0) throw SortError.NegativeWeight("${edge.a}-${edge.b}", edge.weightQ)
    }
    for (entry in snapshot.entries) {
        checkId(entry.productId, "entry.product_id")
        if (entry.weightQ < 0) throw SortError.NegativeWeight("entry ${entry.productId}", entry.weightQ)
    }
}

private fun checkId(
    id: String,
    field: String,
) {
    if (!isValidId(id)) throw SortError.InvalidId(field, id)
}
