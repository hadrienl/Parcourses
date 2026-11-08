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

    @Query("SELECT * FROM lists WHERE id = :id")
    fun observe(id: String): Flow<ShoppingListEntity?>

    /** Toutes les listes, supprimées comprises : sert à la synchronisation et à la réconciliation de la file. */
    @Query("SELECT * FROM lists ORDER BY createdAt, id")
    suspend fun getAll(): List<ShoppingListEntity>

    @Upsert
    suspend fun upsert(list: ShoppingListEntity)

    @Query("UPDATE lists SET name = :name, updatedAt = :at, syncState = :state WHERE id = :id")
    suspend fun rename(id: String, name: String, at: Instant, state: SyncState = SyncState.PENDING): Int

    /** Suppression douce : la liste disparaît de [observeActive] et reste en base jusqu'à l'envoi. */
    @Query("UPDATE lists SET deletedAt = :at, updatedAt = :at, syncState = :state WHERE id = :id")
    suspend fun markDeleted(id: String, at: Instant, state: SyncState = SyncState.PENDING): Int

    @Query("UPDATE lists SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(id: String, state: SyncState): Int

    @Query("DELETE FROM lists WHERE id = :id")
    suspend fun delete(id: String): Int
}

@Dao
interface ListItemDao {
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
    suspend fun setChecked(id: String, checkedAt: Instant?, at: Instant, state: SyncState = SyncState.PENDING): Int

    /** Ne touche pas `updatedAt` ni `syncState` : « introuvable » reste local (#9.9). */
    @Query("UPDATE list_items SET notFoundAt = :notFoundAt WHERE id = :id")
    suspend fun setNotFound(id: String, notFoundAt: Instant?): Int

    @Query("UPDATE list_items SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(id: String, state: SyncState): Int

    @Query("DELETE FROM list_items WHERE id = :id")
    suspend fun delete(id: String): Int

    @Query("DELETE FROM list_items WHERE listId = :listId")
    suspend fun deleteByList(listId: String): Int
}

@Dao
interface ProductDao {
    @Query("SELECT * FROM products ORDER BY normalizedName, id")
    suspend fun getAll(): List<ProductEntity>

    @Query("SELECT * FROM products WHERE id = :id")
    suspend fun get(id: String): ProductEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAll(products: List<ProductEntity>)
}
