package fr.parcourses.core.database.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.OnConflictStrategy
import androidx.room3.Query
import androidx.room3.Upsert
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.SyncState
import kotlinx.coroutines.flow.Flow
import kotlin.time.Instant

@Dao
interface ShoppingListDao {
    /** Listes non supprimées, la plus récemment modifiée d'abord. */
    @Query("SELECT * FROM lists WHERE deletedAt IS NULL ORDER BY updatedAt DESC, id")
    fun observeActive(): Flow<List<ShoppingListEntity>>

    @Query("SELECT * FROM lists WHERE id = :id")
    suspend fun get(id: String): ShoppingListEntity?

    /** Listes à envoyer (non supprimées ou non), les plus anciennes d'abord. */
    @Query("SELECT * FROM lists WHERE syncState = 'PENDING' ORDER BY createdAt, id")
    suspend fun pending(): List<ShoppingListEntity>

    @Query("SELECT id FROM lists WHERE deletedAt IS NOT NULL")
    suspend fun deletedIds(): List<String>

    @Query("SELECT * FROM lists WHERE id = :id")
    fun observe(id: String): Flow<ShoppingListEntity?>

    /** Toutes les listes, supprimées comprises : sert à la synchronisation et à la réconciliation de la file. */
    @Query("SELECT * FROM lists ORDER BY createdAt, id")
    suspend fun getAll(): List<ShoppingListEntity>

    @Upsert
    suspend fun upsert(list: ShoppingListEntity)

    @Query("UPDATE lists SET name = :name, updatedAt = :at, syncState = :state WHERE id = :id")
    suspend fun rename(
        id: String,
        name: String,
        at: Instant,
        state: SyncState = SyncState.PENDING,
    ): Int

    /** Suppression douce : la liste disparaît de [observeActive] et reste en base jusqu'à l'envoi. */
    @Query("UPDATE lists SET deletedAt = :at, updatedAt = :at, syncState = :state WHERE id = :id")
    suspend fun markDeleted(
        id: String,
        at: Instant,
        state: SyncState = SyncState.PENDING,
    ): Int

    @Query("UPDATE lists SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(
        id: String,
        state: SyncState,
    ): Int

    @Query("DELETE FROM lists WHERE id = :id")
    suspend fun delete(id: String): Int
}

// Un DAO est une liste plate de requêtes : le plafond de fonctions de detekt n'a pas de sens ici.

/** Nombre d'articles d'une liste et ce qui reste à acheter. */
data class ListCounts(
    val listId: String,
    val total: Int,
    val remaining: Int,
)

@Suppress("TooManyFunctions")
@Dao
interface ListItemDao {
    /** Compteurs de toutes les listes, recalculés à chaque écriture sur les articles. */
    @Query(
        "SELECT listId, COUNT(*) AS total, SUM(CASE WHEN checkedAt IS NULL THEN 1 ELSE 0 END) AS remaining " +
            "FROM list_items GROUP BY listId",
    )
    fun observeCounts(): Flow<List<ListCounts>>

    /** Historique d'autocomplétion : articles des listes non supprimées. */
    @Query(
        "SELECT i.* FROM list_items i JOIN lists l ON l.id = i.listId " +
            "WHERE l.deletedAt IS NULL ORDER BY i.updatedAt DESC, i.id",
    )
    fun observeHistory(): Flow<List<ListItemEntity>>

    @Query("SELECT * FROM list_items ORDER BY position, id")
    suspend fun getAll(): List<ListItemEntity>

    /** Articles à envoyer, dans l'ordre de saisie. */
    @Query("SELECT * FROM list_items WHERE syncState = 'PENDING' ORDER BY position, id")
    suspend fun pending(): List<ListItemEntity>

    /** Articles sans produit partagé, candidats à `resolve_products` : ordre total (date, puis id). */
    @Query("SELECT * FROM list_items WHERE productId IS NULL ORDER BY updatedAt, id")
    suspend fun withoutProduct(): List<ListItemEntity>

    /** Articles d'une liste, triés par `position`. */
    @Query("SELECT * FROM list_items WHERE listId = :listId ORDER BY position, id")
    fun observeByList(listId: String): Flow<List<ListItemEntity>>

    @Query("SELECT * FROM list_items WHERE listId = :listId ORDER BY position, id")
    suspend fun getByList(listId: String): List<ListItemEntity>

    @Query("SELECT * FROM list_items WHERE id = :id")
    suspend fun get(id: String): ListItemEntity?

    /** Prochaine `position` libre dans la liste (0 si elle est vide). */
    @Query("SELECT COALESCE(MAX(position) + 1, 0) FROM list_items WHERE listId = :listId")
    suspend fun nextPosition(listId: String): Int

    /** Articles de toutes les listes non supprimées, source de l'autocomplétion. */
    @Query(
        "SELECT i.* FROM list_items i JOIN lists l ON l.id = i.listId " +
            "WHERE l.deletedAt IS NULL ORDER BY i.updatedAt DESC, i.id",
    )
    suspend fun itemHistory(): List<ListItemEntity>

    @Upsert
    suspend fun upsert(item: ListItemEntity)

    @Upsert
    suspend fun upsertAll(items: List<ListItemEntity>)

    @Query("UPDATE list_items SET checkedAt = :checkedAt, updatedAt = :at, syncState = :state WHERE id = :id")
    suspend fun setChecked(
        id: String,
        checkedAt: Instant?,
        at: Instant,
        state: SyncState = SyncState.PENDING,
    ): Int

    /** Ne touche pas `updatedAt` ni `syncState` : « introuvable » reste local (#9.9). */
    @Query("UPDATE list_items SET notFoundAt = :notFoundAt WHERE id = :id")
    suspend fun setNotFound(
        id: String,
        notFoundAt: Instant?,
    ): Int

    /**
     * Les introuvables de la liste reviennent à acheter. Local comme [setNotFound] : ni `updatedAt` ni `syncState`.
     * Renvoie le nombre d'articles remis.
     */
    @Query("UPDATE list_items SET notFoundAt = NULL WHERE listId = :listId AND notFoundAt IS NOT NULL")
    suspend fun clearNotFound(listId: String): Int

    @Query("UPDATE list_items SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(
        id: String,
        state: SyncState,
    ): Int

    @Query("DELETE FROM list_items WHERE id = :id")
    suspend fun delete(id: String): Int

    @Query("DELETE FROM list_items WHERE listId = :listId")
    suspend fun deleteByList(listId: String): Int
}

@Dao
interface ProductDao {
    @Query("SELECT * FROM products ORDER BY normalizedName, id")
    suspend fun getAll(): List<ProductEntity>

    @Query("SELECT * FROM products ORDER BY normalizedName, id")
    fun observeAll(): Flow<List<ProductEntity>>

    @Query("DELETE FROM products")
    suspend fun deleteAll(): Int

    @Query("SELECT * FROM products WHERE id = :id")
    suspend fun get(id: String): ProductEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(products: List<ProductEntity>)
}
