package fr.parcourses.core.database.dao

import androidx.room3.Dao
import androidx.room3.Query
import androidx.room3.Upsert
import fr.parcourses.core.database.entity.ListParticipantEntity
import kotlinx.coroutines.flow.Flow

/** Personnes des listes (#87, lot 87.6), remplacées en bloc à chaque descente. */
@Dao
interface ListParticipantDao {
    /** Participants de toutes les listes, dans l'ordre d'arrivée (le propriétaire d'abord). */
    @Query("SELECT * FROM list_participants ORDER BY listId, role = 'Owner' DESC, joinedAt, userId")
    fun observeAll(): Flow<List<ListParticipantEntity>>

    @Query("SELECT * FROM list_participants WHERE listId = :listId ORDER BY role = 'Owner' DESC, joinedAt, userId")
    fun observe(listId: String): Flow<List<ListParticipantEntity>>

    @Query("SELECT * FROM list_participants WHERE listId = :listId ORDER BY role = 'Owner' DESC, joinedAt, userId")
    suspend fun get(listId: String): List<ListParticipantEntity>

    @Query("SELECT * FROM list_participants")
    suspend fun all(): List<ListParticipantEntity>

    @Upsert
    suspend fun upsertAll(participants: List<ListParticipantEntity>)

    @Query("DELETE FROM list_participants WHERE listId = :listId")
    suspend fun deleteByList(listId: String): Int

    @Query("DELETE FROM list_participants")
    suspend fun deleteAll(): Int
}
