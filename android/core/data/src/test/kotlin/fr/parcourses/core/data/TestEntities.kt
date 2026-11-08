package fr.parcourses.core.data

import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.database.entity.VisitEntity
import kotlin.time.Instant
import kotlin.uuid.Uuid

fun DataTest.visit(
    listId: String,
    state: SyncState = SyncState.PENDING,
    startedAt: Instant = Instant.fromEpochSeconds(1_000_000),
) = VisitEntity(
    id = Uuid.random().toString(),
    storeId = Uuid.random().toString(),
    listId = listId,
    listWasSorted = false,
    startedAt = startedAt,
    syncState = state,
)

fun DataTest.check(
    visitId: String,
    itemId: String,
    productId: String? = null,
    categoryId: String? = "dairy",
    at: Instant = Instant.fromEpochSeconds(1_000_001),
) = CheckEntity(
    id = Uuid.random().toString(),
    visitId = visitId,
    itemId = itemId,
    productId = productId,
    categoryId = if (productId == null) categoryId else null,
    checkedAt = at,
)
