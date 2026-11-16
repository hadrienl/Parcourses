package fr.parcourses.core.data

import fr.parcourses.core.categorizer.ItemQuantity
import fr.parcourses.core.data.repository.ListRepository
import kotlin.time.Instant

/**
 * Ce que le panneau de l'article enregistre (#110, même nom qu'iOS) : libellé sans blancs de bord, au plus
 * [MAX_LABEL_LENGTH] caractères, et quantité nettoyée par [ItemQuantity.quantityInput].
 */
data class ItemEdit(
    val label: String,
    val quantity: String?,
) {
    companion object {
        /** `list_items.label` : 200 caractères au plus (`char_length`, en points de code). */
        const val MAX_LABEL_LENGTH = 200

        /** Valeurs du formulaire ; `null` si le libellé est vide. */
        fun of(
            label: String,
            quantityText: String,
        ): ItemEdit? {
            val trimmed = label.trim()
            if (trimmed.isEmpty()) return null
            val end =
                if (trimmed.codePointCount(0, trimmed.length) > MAX_LABEL_LENGTH) {
                    trimmed.offsetByCodePoints(0, MAX_LABEL_LENGTH)
                } else {
                    trimmed.length
                }
            return ItemEdit(trimmed.substring(0, end), ItemQuantity.quantityInput(quantityText))
        }
    }
}

/**
 * Enregistre le panneau de l'article (#110) : le libellé est reclassé tel quel (forme normalisée et rayon, comme à
 * l'ajout, sans en séparer de quantité), puis [ListRepository.updateItem] n'écrit que ce qui change. `apply(_:to:)`
 * d'iOS (renommée : `apply` est une fonction de portée de Kotlin).
 */
suspend fun ListRepository.applyEdit(
    edit: ItemEdit,
    itemId: String,
    analyzer: EntryAnalyzer,
    at: Instant,
) {
    val entry = analyzer.analyzeLabel(edit.label)
    updateItem(itemId, entry.label, entry.normalizedName, entry.categoryId, edit.quantity, at)
}
