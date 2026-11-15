package fr.parcourses.core.data.outbox

import fr.parcourses.core.data.sync.SyncDecisions
import fr.parcourses.core.database.dao.OutboxDao
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.VisitEntity
import fr.parcourses.core.network.dto.ListItemFields
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

    /**
     * Remplace l'entrée en attente de l'article. [changedFields] (noms de colonnes serveur, [ItemFields]) s'unit à
     * ceux de l'entrée remplacée (vecteur `002`) : seuls ces champs partiront si l'article est déjà sur le serveur.
     * Une entrée remplacée d'avant la version 2 de la base (`changedFields` nul) le reste : tous les champs partent.
     */
    suspend fun enqueueUpsert(
        item: ListItemEntity,
        at: Instant,
        changedFields: Collection<String> = ItemFields.ALL,
    ) {
        val replaced = dao.pendingFor(item.id).filter { it.kind() == OutboxKind.UpsertItem }
        val fields =
            if (replaced.any { it.changedFields == null }) {
                null
            } else {
                SyncDecisions.mergeChangedFields(
                    replaced.flatMap { ItemFields.decode(it.changedFields) },
                    changedFields,
                )
            }
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
            changedFields = fields?.let(ItemFields::encode),
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

    /**
     * [isOnServer] : l'article avait atteint le serveur. Sinon une suppression sans ligne n'a rien d'ambigu : il
     * n'y est jamais arrivé (#87).
     */
    suspend fun enqueueDeletion(
        ofItem: String,
        listId: String,
        at: Instant,
        isOnServer: Boolean = true,
    ) {
        dao.cancelPending(ofItem, setOf(OutboxKind.UpsertItem))
        dao.enqueue(
            newId(),
            OutboxKind.DeleteItem,
            ofItem,
            OutboxCoding.encode(ItemDeletionPayload.serializer(), ItemDeletionPayload(listId, isOnServer)),
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

/** Champs d'un article qu'un changement local peut modifier, en noms de colonnes serveur (#87 §6.4). */
object ItemFields {
    const val CHECKED_AT = ListItemFields.CHECKED_AT
    const val LABEL = ListItemFields.LABEL
    const val PRODUCT_ID = ListItemFields.PRODUCT_ID
    const val QUANTITY = ListItemFields.QUANTITY

    /** Un article créé, ou une entrée reconstruite sans rien savoir des champs changés : tout (même règle qu'iOS). */
    val ALL: List<String> = ListItemFields.ALL

    private const val SEPARATOR = ","

    fun encode(fields: Collection<String>): String = fields.sorted().distinct().joinToString(SEPARATOR)

    /** `null` (entrée d'avant la version 2) : aucun champ connu, l'appelant décide. */
    fun decode(value: String?): List<String> = value?.split(SEPARATOR)?.filter { it.isNotEmpty() }.orEmpty()
}
