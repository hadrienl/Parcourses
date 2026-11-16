package fr.parcourses.core.data

import fr.parcourses.core.categorizer.ItemQuantity
import fr.parcourses.core.data.repository.ListRepository
import fr.parcourses.core.data.repository.RepositoryException
import kotlin.time.Instant

/**
 * Ce que l'utilisateur a changé dans le panneau de l'article (#110, même nom qu'iOS), par rapport à l'instantané
 * pris à l'ouverture : seul ce qui a changé est écrit, un changement venu d'un autre appareil pendant que le panneau
 * était ouvert n'est pas annulé.
 *
 * [label] : nouveau libellé sans blancs de bord, au plus [MAX_LABEL_LENGTH] points de code ; `null` s'il est
 * identique à celui de l'ouverture. [changesQuantity] : la quantité nettoyée ([ItemQuantity.quantityInput]) diffère
 * de celle de l'ouverture ; [quantity] est alors la nouvelle valeur (`null` : quantité effacée).
 */
data class ItemEdit(
    val label: String?,
    val changesQuantity: Boolean,
    val quantity: String?,
) {
    /** Rien n'a changé : aucune écriture. */
    val isEmpty: Boolean get() = label == null && !changesQuantity

    companion object {
        /** `list_items.label` : 200 caractères au plus (`char_length`, en points de code). */
        /** Retours à la ligne au sens de Swift (`Character.isNewline`) : LF, CR, VT, FF, U+0085, U+2028, U+2029. */
        private val NEWLINES = Regex("[\\n\\r\\u000B\\u000C\\u0085\\u2028\\u2029]+")

        const val MAX_LABEL_LENGTH = 200

        /**
         * Valeurs du formulaire comparées à l'instantané d'ouverture ([originalLabel], [originalQuantity]) ; `null` si
         * le libellé est vide.
         */
        fun of(
            originalLabel: String,
            originalQuantity: String?,
            label: String,
            quantityText: String,
        ): ItemEdit? {
            // Chaque suite de retours à la ligne (collés, ou venus d'iOS) devient une espace : le libellé tient sur une
            // ligne. Même règle qu'iOS (`Character.isNewline`).
            val trimmed = label.replace(NEWLINES, " ").trim()
            if (trimmed.isEmpty()) return null
            val end =
                if (trimmed.codePointCount(0, trimmed.length) > MAX_LABEL_LENGTH) {
                    trimmed.offsetByCodePoints(0, MAX_LABEL_LENGTH)
                } else {
                    trimmed.length
                }
            val newLabel = trimmed.substring(0, end)
            val quantity = ItemQuantity.quantityInput(quantityText)
            return ItemEdit(
                label = newLabel.takeIf { it != originalLabel },
                changesQuantity = quantity != originalQuantity,
                quantity = quantity,
            )
        }
    }
}

/**
 * Enregistre le panneau de l'article (#110). L'article est relu en base : ce qui n'a pas été changé dans le panneau
 * garde sa valeur actuelle. Un nouveau libellé est reclassé tel quel (forme normalisée et rayon, comme à l'ajout, sans
 * en séparer de quantité), puis [ListRepository.updateItem] n'écrit que ce qui change. Une édition vide n'écrit rien ;
 * un article disparu donne [RepositoryException.NotFound]. `apply(_:to:)` d'iOS (renommée : `apply` est une fonction
 * de portée de Kotlin).
 */
suspend fun ListRepository.applyEdit(
    edit: ItemEdit,
    itemId: String,
    analyzer: EntryAnalyzer,
    at: Instant,
) {
    if (edit.isEmpty) return
    val item = item(itemId) ?: throw RepositoryException.NotFound(itemId)
    val relabeled = edit.label?.let(analyzer::analyzeLabel)
    updateItem(
        itemId = itemId,
        label = relabeled?.label ?: item.label,
        normalizedName = relabeled?.normalizedName ?: item.normalizedName,
        categoryId = relabeled?.categoryId ?: item.categoryId,
        quantity = if (edit.changesQuantity) edit.quantity else item.quantity,
        at = at,
    )
}
