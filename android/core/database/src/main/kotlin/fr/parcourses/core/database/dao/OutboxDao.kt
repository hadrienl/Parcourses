package fr.parcourses.core.database.dao

import androidx.room3.Dao
import androidx.room3.Insert
import androidx.room3.Query
import androidx.room3.Transaction
import fr.parcourses.core.database.entity.OutboxEntryEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import kotlin.time.Instant

@Dao
abstract class OutboxDao {
    @Insert
    protected abstract suspend fun insert(entry: OutboxEntryEntity)

    @Query("SELECT COALESCE(MAX(sequence), 0) FROM outbox")
    protected abstract suspend fun maxSequence(): Long

    /** Entrées en attente (`PENDING`), dans l'ordre de la file. */
    @Query("SELECT * FROM outbox WHERE syncState = 'PENDING' ORDER BY sequence")
    abstract suspend fun pending(): List<OutboxEntryEntity>

    /** Entrées en attente dont l'heure de reprise est passée, dans l'ordre de la file. */
    @Query("SELECT * FROM outbox WHERE syncState = 'PENDING' AND nextAttemptAt <= :now ORDER BY sequence")
    abstract suspend fun due(now: Instant): List<OutboxEntryEntity>

    @Query("SELECT * FROM outbox ORDER BY sequence")
    abstract suspend fun all(): List<OutboxEntryEntity>

    @Query("SELECT * FROM outbox WHERE entityId = :entityId AND syncState = 'PENDING' ORDER BY sequence")
    abstract suspend fun pendingFor(entityId: String): List<OutboxEntryEntity>

    @Query("SELECT COUNT(*) FROM outbox WHERE syncState = 'PENDING'")
    abstract suspend fun pendingCount(): Int

    @Query("DELETE FROM outbox WHERE id = :id")
    abstract suspend fun delete(id: String): Int

    @Query(
        "UPDATE outbox SET attempts = :attempts, nextAttemptAt = :nextAttemptAt, lastError = :lastError, " +
            "serverFailingSince = :serverFailingSince, syncState = :state WHERE id = :id",
    )
    abstract suspend fun recordAttempt(
        id: String,
        attempts: Int,
        nextAttemptAt: Instant,
        lastError: String?,
        serverFailingSince: Instant?,
        state: SyncState,
    ): Int

    /**
     * Ajoute une entrée à la file. `sequence` prolonge la plus grande valeur présente, sauf si [keepingSequence]
     * est fourni (une entrée remplacée garde son rang, sinon la liste passerait derrière ses articles).
     * À appeler dans la même transaction que l'écriture qu'elle accompagne.
     */
    @Transaction
    open suspend fun enqueue(
        id: String,
        kind: OutboxKind,
        entityId: String,
        payload: ByteArray,
        at: Instant,
        keepingSequence: Long? = null,
        notBefore: Instant? = null,
    ): OutboxEntryEntity {
        val entry =
            OutboxEntryEntity(
                id = id,
                sequence = keepingSequence ?: (maxSequence() + 1),
                kindRaw = kind.raw,
                entityId = entityId,
                payload = payload,
                createdAt = at,
                nextAttemptAt = notBefore ?: at,
            )
        insert(entry)
        return entry
    }

    /**
     * Retire les entrées en attente de cette entité pour ces natures. Renvoie la plus petite `sequence` retirée :
     * la remplaçante la reprend.
     */
    @Transaction
    open suspend fun cancelPending(
        entityId: String,
        kinds: Set<OutboxKind>,
    ): Long? {
        val doomed = pendingFor(entityId).filter { it.kind() in kinds }
        doomed.forEach { delete(it.id) }
        return doomed.minOfOrNull { it.sequence }
    }
}
