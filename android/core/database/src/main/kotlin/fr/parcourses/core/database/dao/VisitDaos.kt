package fr.parcourses.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Transaction
import androidx.room3.Upsert
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.GraphSnapshotEntity
import fr.parcourses.core.database.entity.StoreEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.database.entity.VisitEntity
import kotlinx.coroutines.flow.Flow
import kotlin.time.Instant

@Dao
interface VisitDao {
    @Query("SELECT * FROM visits WHERE id = :id")
    suspend fun get(id: String): VisitEntity?

    @Query("SELECT * FROM visits WHERE id = :id")
    fun observe(id: String): Flow<VisitEntity?>

    /** Visites non closes, la plus récente d'abord (il n'y en a qu'une en usage normal, #9.9). */
    @Query("SELECT * FROM visits WHERE endedAt IS NULL ORDER BY startedAt DESC, id")
    suspend fun getOpen(): List<VisitEntity>

    @Query("SELECT * FROM visits ORDER BY startedAt, id")
    suspend fun getAll(): List<VisitEntity>

    @Upsert
    suspend fun upsert(visit: VisitEntity)

    /** Idempotent : une visite déjà close garde son `endedAt`. */
    @Query("UPDATE visits SET endedAt = :endedAt, endSyncState = :state WHERE id = :id AND endedAt IS NULL")
    suspend fun close(
        id: String,
        endedAt: Instant,
        state: SyncState = SyncState.PENDING,
    ): Int

    @Query("UPDATE visits SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(
        id: String,
        state: SyncState,
    ): Int

    @Query("UPDATE visits SET endSyncState = :state WHERE id = :id")
    suspend fun setEndSyncState(
        id: String,
        state: SyncState,
    ): Int

    @Query("DELETE FROM visits WHERE id = :id")
    suspend fun delete(id: String): Int
}

@Dao
interface CheckDao {
    @Query("SELECT * FROM checks WHERE visitId = :visitId ORDER BY checkedAt, id")
    fun observeByVisit(visitId: String): Flow<List<CheckEntity>>

    @Query("SELECT * FROM checks WHERE visitId = :visitId ORDER BY checkedAt, id")
    suspend fun getByVisit(visitId: String): List<CheckEntity>

    @Query("SELECT * FROM checks WHERE id = :id")
    suspend fun get(id: String): CheckEntity?

    @Query("SELECT * FROM checks WHERE itemId = :itemId ORDER BY checkedAt DESC, id LIMIT 1")
    suspend fun latestForItem(itemId: String): CheckEntity?

    @Query("SELECT * FROM checks ORDER BY checkedAt, id")
    suspend fun getAll(): List<CheckEntity>

    @Upsert
    suspend fun upsert(check: CheckEntity)

    @Query("UPDATE checks SET syncState = :state WHERE id = :id")
    suspend fun setSyncState(
        id: String,
        state: SyncState,
    ): Int

    @Query("DELETE FROM checks WHERE id = :id")
    suspend fun delete(id: String): Int

    @Query("DELETE FROM checks WHERE visitId = :visitId")
    suspend fun deleteByVisit(visitId: String): Int
}

@Dao
interface StoreDao {
    @Query("SELECT * FROM stores WHERE id = :id")
    suspend fun get(id: String): StoreEntity?

    /** Magasins déjà utilisés, du plus récent au plus ancien. */
    @Query("SELECT * FROM stores WHERE lastUsedAt IS NOT NULL ORDER BY lastUsedAt DESC, id LIMIT :limit")
    fun observeRecent(limit: Int): Flow<List<StoreEntity>>

    @Query("SELECT * FROM stores WHERE lastUsedAt IS NOT NULL ORDER BY lastUsedAt DESC, id LIMIT :limit")
    suspend fun recent(limit: Int): List<StoreEntity>

    @Upsert
    suspend fun upsert(store: StoreEntity)

    @Query("UPDATE stores SET lastUsedAt = :at WHERE id = :id")
    suspend fun markUsed(
        id: String,
        at: Instant,
    ): Int
}

@Dao
abstract class GraphSnapshotDao {
    @Query("SELECT * FROM graph_snapshots WHERE storeId = :storeId")
    abstract suspend fun get(storeId: String): GraphSnapshotEntity?

    @Query("SELECT * FROM graph_snapshots ORDER BY fetchedAt DESC, storeId")
    abstract suspend fun getAll(): List<GraphSnapshotEntity>

    @Upsert
    abstract suspend fun upsert(snapshot: GraphSnapshotEntity)

    /** Évince les instantanés les plus anciens : on garde les [keep] derniers (LRU, #9 §4.2). */
    @Query(
        "DELETE FROM graph_snapshots WHERE storeId NOT IN " +
            "(SELECT storeId FROM graph_snapshots ORDER BY fetchedAt DESC, storeId LIMIT :keep)",
    )
    abstract suspend fun trim(keep: Int): Int

    /** Remplace l'instantané du magasin et évince les plus anciens, dans la même transaction. */
    @Transaction
    open suspend fun saveSnapshot(
        snapshot: GraphSnapshotEntity,
        keep: Int = MAX_SNAPSHOTS,
    ) {
        upsert(snapshot)
        trim(keep)
    }

    companion object {
        /** Nombre de magasins dont on garde l'instantané (#9 §4.2). */
        const val MAX_SNAPSHOTS = 5
    }
}
