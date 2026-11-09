// Port de la réconciliation d'iOS : une garde `continue` par cas écarté, conditions de la règle 42501.
@file:Suppress("LoopWithTooManyJumpStatements", "CyclomaticComplexMethod", "ComplexCondition")

package fr.parcourses.core.data.sync

import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.OutboxDependencies
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.SyncState
import kotlin.time.Instant

/**
 * Remet la file d'accord avec les données locales (liste, article ou visite `PENDING` sans entrée active).
 *
 * Une donnée peut être `PENDING` sans entrée : liste créée avant l'existence de la file, entrée perdue, ou
 * abandonnée en `FAILED` pour une cause qui n'en était pas une (article refusé parce que sa liste n'était jamais
 * partie). Sans entrée, rien ne l'enverrait jamais.
 *
 * Rejouable et idempotente : une entité qui a déjà une entrée `PENDING` n'en reçoit pas de seconde. Les entrées
 * sont ajoutées dans l'ordre des dépendances (liste, articles, visites, coches, clôtures). Même règle qu'iOS
 * (`OutboxReconciliation`).
 */
class OutboxReconciliation(
    private val db: ParcoursesDatabase,
    private val queue: OutboxQueue = OutboxQueue(db.outbox()),
) {
    /** Nombre d'entrées ajoutées ou rendues à la file. */
    suspend fun run(now: Instant): Int =
        db.withWriteTransaction {
            val queued = activeKinds()
            var count = reconcileLists(queued, now)
            count += reconcileItems(queued, now)
            count += revokeWrongfulFailures(now)
            count + reconcileVisits(queued, now)
        }

    private suspend fun reconcileLists(
        queued: MutableMap<String, MutableSet<OutboxKind>>,
        now: Instant,
    ): Int {
        var count = 0
        for (list in db.lists().pending()) {
            val kind = if (list.deletedAt != null) OutboxKind.DeleteList else OutboxKind.UpsertList
            if (queued[list.id]?.contains(kind) == true) continue
            if (kind == OutboxKind.DeleteList) queue.enqueueDeletion(list.id, now) else queue.enqueueUpsert(list, now)
            queued.getOrPut(list.id) { mutableSetOf() }.add(kind)
            count++
        }
        return count
    }

    private suspend fun reconcileItems(
        queued: MutableMap<String, MutableSet<OutboxKind>>,
        now: Instant,
    ): Int {
        var count = 0
        for (item in db.items().pending()) {
            if (queued[item.id]?.contains(OutboxKind.UpsertItem) == true) continue
            if (!isActive(item.listId)) continue
            queue.enqueueUpsert(item, now)
            count++
        }
        return count
    }

    private suspend fun reconcileVisits(
        queued: Map<String, Set<OutboxKind>>,
        now: Instant,
    ): Int {
        var count = 0
        val checksByVisit = db.checks().getAll().groupBy { it.visitId }
        for (visit in db.visits().getAll()) {
            val checks = checksByVisit[visit.id].orEmpty()
            // Sans coche, une visite reste locale (#9 §5.5), sauf si le serveur l'a déjà reçue : sa clôture doit
            // partir (#62).
            if (checks.isEmpty() && visit.syncState != SyncState.SYNCED) continue

            fun missing(
                id: String,
                kind: OutboxKind,
            ) = queued[id]?.contains(kind) != true
            if (visit.syncState == SyncState.PENDING && missing(visit.id, OutboxKind.CreateVisit)) {
                queue.enqueueCreation(visit, visit.listId.takeIf { isActive(it) }, now)
                count++
            }
            // Visite abandonnée : ses coches n'ont plus d'objet.
            if (visit.syncState == SyncState.FAILED) continue
            for (check in checks) {
                if (check.syncState == SyncState.PENDING && missing(check.id, OutboxKind.InsertChecks)) {
                    queue.enqueueInsertion(check, now)
                    count++
                }
            }
            val endedAt = visit.endedAt
            if (endedAt != null && visit.endSyncState == SyncState.PENDING &&
                missing(visit.id, OutboxKind.CloseVisit)
            ) {
                queue.enqueueClosure(visit.id, endedAt, now)
                count++
            }
        }
        return count
    }

    /**
     * Les articles abandonnés en `42501` alors que leur liste n'est jamais partie repartent, derrière elle.
     * Remplacés par une entrée neuve : la valeur courante de l'article part, jamais une valeur périmée.
     */
    private suspend fun revokeWrongfulFailures(now: Instant): Int {
        var count = 0
        for (entry in db.outbox().failed()) {
            if (entry.kind() != OutboxKind.UpsertItem || entry.lastError != FORBIDDEN_REASON) continue
            val listId = OutboxDependencies.listId(entry) ?: continue
            val list = db.lists().get(listId)
            val item = db.items().get(entry.entityId)
            if (list == null || list.deletedAt != null || list.syncState != SyncState.PENDING || item == null) continue
            db.outbox().delete(entry.id)
            val hasActive = db.outbox().pendingFor(item.id).isNotEmpty()
            db.items().setSyncState(item.id, SyncState.PENDING)
            if (!hasActive) {
                queue.enqueueUpsert(item.copy(syncState = SyncState.PENDING), now)
                count++
            }
        }
        return count
    }

    private suspend fun activeKinds(): MutableMap<String, MutableSet<OutboxKind>> {
        val kinds = mutableMapOf<String, MutableSet<OutboxKind>>()
        for (entry in db.outbox().pending()) {
            entry.kind()?.let { kinds.getOrPut(entry.entityId) { mutableSetOf() }.add(it) }
        }
        return kinds
    }

    private suspend fun isActive(listId: String): Boolean =
        db.lists().get(listId)?.let { it.deletedAt == null } ?: false

    companion object {
        /** Cause d'un article abandonné à tort : `42501` tant que sa liste n'existe pas chez le serveur. */
        const val FORBIDDEN_REASON = "42501"
    }
}
