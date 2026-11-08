package fr.parcourses.feature.lists

import androidx.compose.runtime.Immutable
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ProductEntity
import kotlin.time.Instant

/** Proposition d'autocomplétion. */
@Immutable
data class ItemSuggestion(
    /** Forme normalisée : deux saisies de même forme ne font qu'une proposition. */
    val normalizedName: String,
    val label: String,
    val productId: String?,
    val categoryId: String?,
    val useCount: Int,
    val lastUsedAt: Instant?,
) {
    val id: String get() = normalizedName
}

/**
 * Index d'autocomplétion : historique de l'utilisateur et catalogue local. Calcul pur, en mémoire : recherché à
 * chaque frappe sans toucher à la base. Mêmes règles que `ItemSuggestionIndex` d'iOS.
 */
class ItemSuggestionIndex(
    history: List<ListItemEntity>,
    products: List<ProductEntity>,
    normalizeFallback: (String) -> String,
) {
    private val entries: List<ItemSuggestion>

    init {
        val byName = mutableMapOf<String, ItemSuggestion>()
        // Ordres totaux : à date égale, le résultat ne dépend pas de l'ordre rendu par la base.
        for (product in products.sortedBy { it.id }) {
            val key = product.normalizedName.ifEmpty { normalizeFallback(product.name) }
            if (key.isEmpty()) continue
            byName[key] = ItemSuggestion(key, product.name, product.id, product.categoryId, 0, null)
        }
        // Du plus ancien au plus récent : le dernier libellé saisi l'emporte.
        for (item in history.sortedWith(compareBy<ListItemEntity> { it.updatedAt }.thenBy { it.id })) {
            val key = item.normalizedName.ifEmpty { normalizeFallback(item.label) }
            if (key.isEmpty()) continue
            val known = byName[key]
            byName[key] =
                ItemSuggestion(
                    normalizedName = key,
                    label = item.label,
                    productId = item.productId ?: known?.productId,
                    categoryId = item.categoryId,
                    useCount = (known?.useCount ?: 0) + 1,
                    lastUsedAt = item.updatedAt,
                )
        }
        entries = byName.values.sortedWith(RANKING)
    }

    /** Propositions dont un mot commence par l'une des formes, hors articles déjà à acheter. */
    fun suggestions(
        forms: List<String>,
        excluding: Set<String>,
        limit: Int = DEFAULT_LIMIT,
    ): List<ItemSuggestion> {
        if (forms.isEmpty()) return emptyList()
        return entries
            .asSequence()
            .filter { entry ->
                entry.normalizedName !in excluding &&
                    forms.any { entry.normalizedName.startsWith(it) || entry.normalizedName.contains(" $it") }
            }.take(limit)
            .toList()
    }

    private companion object {
        const val DEFAULT_LIMIT = 5

        /** Le plus utilisé, puis le plus récent, puis l'identifiant (octets UTF-8, comme iOS). */
        val RANKING: Comparator<ItemSuggestion> =
            compareByDescending<ItemSuggestion> { it.useCount }
                .thenByDescending { it.lastUsedAt ?: Instant.DISTANT_PAST }
                .thenComparator { a, b -> compareUtf8(a.id, b.id) }

        fun compareUtf8(
            a: String,
            b: String,
        ): Int {
            val x = a.encodeToByteArray()
            val y = b.encodeToByteArray()
            for (i in 0 until minOf(x.size, y.size)) {
                val difference = (x[i].toInt() and 0xFF) - (y[i].toInt() and 0xFF)
                if (difference != 0) return difference
            }
            return x.size - y.size
        }
    }
}
