package fr.parcourses.core.data.outbox

import fr.parcourses.core.database.dao.OutboxDao
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.VisitEntity
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListUpsert
import fr.parcourses.core.network.dto.VisitInsert
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Écritures de la file d'envoi (#9 §5). Chaque méthode est à appeler dans la même transaction que l'écriture
 * qu'elle accompagne : l'une ne va pas sans l'autre.
 */
class OutboxQueue(
    private val dao: OutboxDao,
    private val newId: () -> String = { Uuid.random().toString() },
) {
    /** Remplace l'entrée en attente de la liste : elle garde son rang et le départ de panne. */
    suspend fun enqueueUpsert(
        list: ShoppingListEntity,
        at: Instant,
    ) {
        val row = ListUpsert(id = list.id.asUuid(), name = list.name)
        dao.replacePending(
            id = newId(),
            kind = OutboxKind.UpsertList,
            entityId = list.id,
            payload = OutboxCoding.encode(ListUpsert.serializer(), row),
            at = at,
        )
    }

    suspend fun enqueueUpsert(
        item: ListItemEntity,
        at: Instant,
    ) {
        val row =
            ListItemUpsert(
                id = item.id.asUuid(),
                listId = item.listId.asUuid(),
                productId = item.productId?.asUuid(),
                label = item.label,
                quantity = item.quantity,
                checkedAt = item.checkedAt,
            )
        dao.replacePending(
            id = newId(),
            kind = OutboxKind.UpsertItem,
            entityId = item.id,
            payload = OutboxCoding.encode(ListItemUpsert.serializer(), row),
            at = at,
        )
    }

    /**
     * Plus rien de la liste ni de ses articles ne doit partir avant sa suppression : les entrées en attente de la
     * liste et de ses articles sont purgées (le serveur supprime les articles en cascade).
     */
    suspend fun enqueueDeletion(
        ofList: String,
        at: Instant,
    ) {
        for (entry in dao.pending()) {
            val doomed =
                when (entry.kind()) {
                    OutboxKind.UpsertList -> entry.entityId == ofList
                    OutboxKind.UpsertItem, OutboxKind.DeleteItem -> OutboxDependencies.listId(entry) == ofList
                    else -> false
                }
            if (doomed) dao.delete(entry.id)
        }
        dao.enqueue(newId(), OutboxKind.DeleteList, ofList, ByteArray(0), at)
    }

    suspend fun enqueueDeletion(
        ofItem: String,
        listId: String,
        at: Instant,
    ) {
        dao.cancelPending(ofItem, setOf(OutboxKind.UpsertItem))
        dao.enqueue(
            newId(),
            OutboxKind.DeleteItem,
            ofItem,
            OutboxCoding.encode(ItemDeletionPayload.serializer(), ItemDeletionPayload(listId)),
            at,
        )
    }

    /**
     * Entrée de création de la visite : différée à la première coche, une visite sans coche ne part jamais (#9 §5.5).
     * `notBefore` : voir [enqueueInsertion].
     */
    suspend fun enqueueCreation(
        visit: VisitEntity,
        listId: String?,
        at: Instant,
        notBefore: Instant? = null,
    ) {
        val row =
            VisitInsert(
                id = visit.id.asUuid(),
                storeId = visit.storeId.asUuid(),
                listId = listId?.asUuid(),
                listWasSorted = visit.listWasSorted,
                startedAt = visit.startedAt,
            )
        dao.enqueue(
            newId(),
            OutboxKind.CreateVisit,
            visit.id,
            OutboxCoding.encode(VisitInsert.serializer(), row),
            at,
            notBefore = notBefore,
        )
    }

    /** `notBefore` retient l'envoi le temps de l'annulation : une coche partie est immuable sur le serveur. */
    suspend fun enqueueInsertion(
        check: CheckEntity,
        at: Instant,
        notBefore: Instant? = null,
    ) {
        dao.enqueue(
            newId(),
            OutboxKind.InsertChecks,
            check.id,
            OutboxCoding.encode(CheckPayload.serializer(), CheckPayload(check)),
            at,
            notBefore = notBefore,
        )
    }

    suspend fun enqueueClosure(
        visitId: String,
        endedAt: Instant,
        at: Instant,
    ) {
        dao.enqueue(
            newId(),
            OutboxKind.CloseVisit,
            visitId,
            OutboxCoding.encode(VisitClosePayload.serializer(), VisitClosePayload(visitId, endedAt)),
            at,
        )
    }
}
