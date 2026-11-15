package fr.parcourses.core.data.sync

import fr.parcourses.core.database.entity.OutboxKind

/**
 * Lot prêt à partir : une entrée, ou plusieurs coches d'une même visite. [changedFields] : celui de l'entrée d'un
 * article (`OutboxEntryEntity.changedFields`), `null` pour les autres et pour une entrée d'avant la version 2.
 */
class OutboxWork(
    val entryIds: List<String>,
    val kind: OutboxKind,
    val entityId: String,
    val payloads: List<ByteArray>,
    val attempts: Int,
    val changedFields: String? = null,
)
