package fr.parcourses.core.database

import fr.parcourses.core.categorizer.CategoryResources

/** Une catégorie à amorcer, indépendante du module du classifieur pour rester testable. */
data class SeedCategory(
    val id: String,
    val rank: Int,
    val label: String,
)

/** Référentiel de catégories à appliquer à la base (pré-remplissage, #10 A4). */
data class CategorySeed(
    val version: Int,
    val categories: List<SeedCategory>,
    /**
     * Identifiants renommés depuis les versions précédentes de `categories.json` (ancien vers nouveau).
     * À compléter en même temps que le fichier, avec une hausse de sa `version`.
     */
    val renamedIds: Map<String, String> = RENAMED_IDS,
) {
    companion object {
        val RENAMED_IDS: Map<String, String> = emptyMap()

        /** Référentiel embarqué, copié de `shared/categories/` dans `:core:categorizer`. */
        fun bundled(): CategorySeed =
            CategorySeed(
                version = CategoryResources.categoriesVersion(),
                categories =
                    CategoryResources.categories().map {
                        SeedCategory(it.id, Math.toIntExact(it.rank), it.labelFr)
                    },
            )
    }
}
