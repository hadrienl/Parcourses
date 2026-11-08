package fr.parcourses.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Upsert
import fr.parcourses.core.categorizer.CategoryClassifier
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.entity.CategoryEntity
import fr.parcourses.core.database.entity.CategorySeedStateEntity
import kotlinx.coroutines.flow.Flow

// Un DAO est une liste plate de requêtes : le plafond de fonctions de detekt n'a pas de sens ici.
@Suppress("TooManyFunctions")
@Dao
abstract class CategoryDao {
    /** Catégories dans l'ordre générique des rayons. */
    @Query("SELECT * FROM categories ORDER BY rank, id")
    abstract fun observeAll(): Flow<List<CategoryEntity>>

    @Query("SELECT * FROM categories ORDER BY rank, id")
    abstract suspend fun getAll(): List<CategoryEntity>

    @Upsert
    abstract suspend fun upsertAll(categories: List<CategoryEntity>)

    @Query("DELETE FROM categories WHERE id IN (:ids)")
    abstract suspend fun deleteByIds(ids: List<String>): Int

    /** Apparie l'identifiant serveur par slug. Ne supprime jamais rien. */
    @Query("UPDATE categories SET remoteId = :remoteId WHERE slug = :slug")
    abstract suspend fun setRemoteId(
        slug: String,
        remoteId: Int,
    ): Int

    /** Le serveur ne connaît pas ce slug (pas encore migré) : l'appariement est retiré. */
    @Query("UPDATE categories SET remoteId = NULL WHERE slug = :slug")
    abstract suspend fun clearRemoteId(slug: String): Int

    @Query("SELECT * FROM category_seed_state WHERE id = :id")
    abstract suspend fun seedState(id: String = CategorySeedStateEntity.SINGLETON_ID): CategorySeedStateEntity?

    @Upsert
    abstract suspend fun upsertSeedState(state: CategorySeedStateEntity)

    /** Renvoie un identifiant de catégorie vers un autre dans les tables qui le portent. */
    @Query("UPDATE list_items SET categoryId = :to WHERE categoryId = :from")
    abstract suspend fun remapItems(
        from: String,
        to: String,
    ): Int

    @Query("UPDATE products SET categoryId = :to WHERE categoryId = :from")
    abstract suspend fun remapProducts(
        from: String,
        to: String,
    ): Int

    @Query("UPDATE checks SET categoryId = :to WHERE categoryId = :from")
    abstract suspend fun remapChecks(
        from: String,
        to: String,
    ): Int

    @Query("SELECT DISTINCT categoryId FROM list_items")
    abstract suspend fun itemCategoryIds(): List<String>

    @Query("SELECT DISTINCT categoryId FROM products WHERE categoryId IS NOT NULL")
    abstract suspend fun productCategoryIds(): List<String>

    @Query("SELECT DISTINCT categoryId FROM checks WHERE categoryId IS NOT NULL")
    abstract suspend fun checkCategoryIds(): List<String>

    /**
     * Applique le référentiel embarqué, seulement si sa version dépasse celle déjà appliquée (comme iOS).
     * Une seule transaction : catégories, remappage des références et version avancent ensemble.
     * Upsert par `id` (le `remoteId` appris est conservé), suppression des absents, renvoi des références
     * vers l'id renommé, ou vers `other` si l'id a disparu sans successeur.
     * Renvoie `true` si le référentiel a été appliqué.
     */
    @Transaction
    open suspend fun seedIfNeeded(seed: CategorySeed): Boolean {
        val applied = seedState()?.version ?: 0
        if (seed.version <= applied) return false

        val existing = getAll().associateBy { it.id }
        val known = seed.categories.map { it.id }.toSet()
        upsertAll(
            seed.categories.map { c ->
                // Le fichier embarqué n'a pas de slug distinct : l'identifiant en tient lieu.
                CategoryEntity(c.id, c.id, c.rank, c.label, existing[c.id]?.remoteId)
            },
        )
        deleteByIds((existing.keys - known).toList())

        fun target(id: String): String {
            val renamed = seed.renamedIds[id] ?: id
            return if (renamed in known) renamed else CategoryClassifier.OTHER_CATEGORY_ID
        }
        for (id in (itemCategoryIds() + productCategoryIds() + checkCategoryIds()).toSet()) {
            val to = target(id)
            if (to != id) {
                remapItems(id, to)
                remapProducts(id, to)
                remapChecks(id, to)
            }
        }
        upsertSeedState(CategorySeedStateEntity(version = seed.version))
        return true
    }
}
