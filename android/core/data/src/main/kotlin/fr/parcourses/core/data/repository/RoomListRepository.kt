package fr.parcourses.core.data.repository

import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.map
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * Implémentation Room. [onEnqueue] est appelé après chaque transaction qui allonge la file (il réveille la
 * synchronisation) ; [newId] fournit les identifiants (UUID minuscules).
 */
@Suppress("TooManyFunctions")
class RoomListRepository(
    private val db: ParcoursesDatabase,
    private val queue: OutboxQueue = OutboxQueue(db.outbox()),
    private val onEnqueue: () -> Unit = {},
    private val newId: () -> String = { Uuid.random().toString() },
) : ListRepository {
    override fun observeSummaries(): Flow<List<ListSummary>> =
        combine(db.lists().observeActive(), db.items().observeCounts()) { lists, counts ->
            val byList = counts.associateBy { it.listId }
            lists.map { list ->
                val count = byList[list.id]
                ListSummary(list.id, list.name, remaining = count?.remaining ?: 0, total = count?.total ?: 0)
            }
        }

    override fun observeList(id: String): Flow<ShoppingListEntity?> =
        db.lists().observe(id).map {
            it?.takeIf { l ->
                l.deletedAt ==
                    null
            }
        }

    override fun observeItems(listId: String): Flow<List<ListItemEntity>> =
        combine(observeList(listId), db.items().observeByList(listId)) { list, items ->
            if (list ==
                null
            ) {
                emptyList()
            } else {
                items
            }
        }

    override fun observeItemHistory(): Flow<List<ListItemEntity>> = db.items().observeHistory()

    override suspend fun lists(): List<ShoppingListEntity> =
        db
            .lists()
            .getAll()
            .filter {
                it.deletedAt == null
            }.sortedByDescending { it.updatedAt }

    override suspend fun list(id: String): ShoppingListEntity? = db.lists().get(id)?.takeIf { it.deletedAt == null }

    override suspend fun items(listId: String): List<ListItemEntity> =
        if (list(listId) ==
            null
        ) {
            emptyList()
        } else {
            db.items().getByList(listId)
        }

    override suspend fun createList(
        name: String,
        at: Instant,
    ): ShoppingListEntity {
        val list = ShoppingListEntity(id = newId(), name = name, createdAt = at, updatedAt = at)
        db.withWriteTransaction {
            db.lists().upsert(list)
            queue.enqueueUpsert(list, at)
        }
        onEnqueue()
        return list
    }

    override suspend fun renameList(
        id: String,
        name: String,
        at: Instant,
    ) {
        // Les vérifications sont dans la transaction : un renvoi ou une reprise de compte ne s'intercale pas.
        db.withWriteTransaction {
            requireActiveList(id)
            db.lists().rename(id, name, at)
            queue.enqueueUpsert(requireActiveList(id), at)
        }
        onEnqueue()
    }

    override suspend fun deleteList(
        id: String,
        at: Instant,
    ) {
        db.withWriteTransaction {
            requireActiveList(id)
            db.lists().markDeleted(id, at)
            queue.enqueueDeletion(id, at)
        }
        onEnqueue()
    }

    override suspend fun addItem(
        listId: String,
        label: String,
        normalizedName: String,
        quantity: String?,
        productId: String?,
        categoryId: String,
        at: Instant,
    ): ListItemEntity {
        val item =
            db.withWriteTransaction {
                requireActiveList(listId)
                val created =
                    ListItemEntity(
                        id = newId(),
                        listId = listId,
                        label = label,
                        normalizedName = normalizedName,
                        quantity = quantity,
                        productId = productId,
                        categoryId = categoryId,
                        position = db.items().nextPosition(listId),
                        updatedAt = at,
                    )
                db.items().upsert(created)
                queue.enqueueUpsert(created, at)
                created
            }
        onEnqueue()
        return item
    }

    override suspend fun setChecked(
        itemId: String,
        checkedAt: Instant?,
        at: Instant,
    ) {
        db.withWriteTransaction {
            requireWritableItem(itemId)
            db.items().setChecked(itemId, checkedAt, at)
            queue.enqueueUpsert(requireNotNull(db.items().get(itemId)), at)
        }
        onEnqueue()
    }

    override suspend fun setNotFound(
        itemId: String,
        notFoundAt: Instant?,
    ) {
        requireWritableItem(itemId)
        db.items().setNotFound(itemId, notFoundAt)
    }

    override suspend fun deleteItem(
        id: String,
        at: Instant,
    ) {
        db.withWriteTransaction {
            val item = requireWritableItem(id)
            queue.enqueueDeletion(ofItem = id, listId = item.listId, at = at)
            db.items().delete(id)
        }
        onEnqueue()
    }

    override suspend fun itemHistory(): List<ListItemEntity> = db.items().itemHistory()

    private suspend fun requireActiveList(id: String): ShoppingListEntity {
        val list = db.lists().get(id) ?: throw RepositoryException.NotFound(id)
        if (list.deletedAt != null) throw RepositoryException.ListDeleted(id)
        return list
    }

    private suspend fun requireWritableItem(id: String): ListItemEntity {
        val item = db.items().get(id) ?: throw RepositoryException.NotFound(id)
        if (db.lists().get(item.listId)?.deletedAt != null) throw RepositoryException.ListDeleted(item.listId)
        return item
    }
}
