package fr.parcourses.core.data.sync

import fr.parcourses.core.database.entity.OutboxKind

/** Lot prêt à partir : une entrée, ou plusieurs coches d'une même visite. */
class OutboxWork(
    val entryIds: List<String>,
    val kind: OutboxKind,
    val entityId: String,
    val payloads: List<ByteArray>,
    val attempts: Int,
)
