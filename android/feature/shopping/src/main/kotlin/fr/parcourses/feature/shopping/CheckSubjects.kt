package fr.parcourses.feature.shopping

import fr.parcourses.core.categorizer.ORGANIC_CATEGORY_ID
import fr.parcourses.core.data.EntryAnalyzer
import fr.parcourses.core.data.repository.CheckSubject
import fr.parcourses.core.database.entity.ListItemEntity

/**
 * Ce que désigne la coche d'[item] : le produit, sinon la catégorie du classifieur, jamais le rayon bio (#28).
 * Même règle pour l'écran et pour « Cocher le suivant » de la Live Update.
 */
internal fun checkSubject(
    item: ListItemEntity,
    analyzer: EntryAnalyzer,
): CheckSubject =
    item.productId?.let { CheckSubject.Product(it) }
        ?: if (item.categoryId == ORGANIC_CATEGORY_ID) {
            CheckSubject.Category(analyzer.classify(item.label).first)
        } else {
            CheckSubject.Category(item.categoryId)
        }
