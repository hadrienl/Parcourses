package fr.parcourses.core.data.outbox

import fr.parcourses.core.database.entity.OutboxEntryEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.VisitInsert
import kotlinx.serialization.SerializationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** Ce qu'une entrée attend, et ce qu'elle retient tant qu'elle n'est pas partie. */
data class OutboxDependency(
    val waits: Set<String>,
    val blocks: Set<String>,
)

/**
 * Dépendances entre entrées (#9 §5.2). Une visite attend sa liste : envoyée trop tôt, elle recevrait un `42501`
 * trompeur. Les coches n'attendent que la création de leur visite, et jamais les autres coches ; la clôture
 * attend toutes les coches.
 */
object OutboxDependencies {
    /** `null` si la charge utile est illisible ou le type inconnu. */
    fun dependency(entry: OutboxEntryEntity): OutboxDependency? =
        when (entry.kind()) {
            OutboxKind.UpsertList -> {
                val key = setOf("list:${entry.entityId}")
                OutboxDependency(waits = key, blocks = key)
            }

            OutboxKind.DeleteList -> {
                val key = "list:${entry.entityId}"
                OutboxDependency(waits = setOf(key, "items:${entry.entityId}"), blocks = setOf(key))
            }

            // Un article en retard ne retient pas ses voisins de liste, seulement la suppression de celle-ci.
            OutboxKind.UpsertItem, OutboxKind.DeleteItem -> {
                listId(entry)?.let { listId ->
                    val own = "item:${entry.entityId}"
                    OutboxDependency(waits = setOf("list:$listId", own), blocks = setOf("items:$listId", own))
                }
            }

            OutboxKind.CreateVisit -> {
                decode(VisitInsert.serializer(), entry)?.let { row ->
                    OutboxDependency(
                        waits = setOfNotNull(row.listId?.let { "list:$it" }),
                        blocks = setOf("create:${row.id}"),
                    )
                }
            }

            OutboxKind.InsertChecks -> {
                visitId(entry)?.let { OutboxDependency(waits = setOf("create:$it"), blocks = setOf("check:$it")) }
            }

            OutboxKind.CloseVisit -> {
                OutboxDependency(
                    waits = setOf("create:${entry.entityId}", "check:${entry.entityId}"),
                    blocks = emptySet(),
                )
            }

            null -> {
                null
            }
        }

    fun listId(entry: OutboxEntryEntity): String? =
        when (entry.kind()) {
            OutboxKind.UpsertItem -> decode(ListItemUpsert.serializer(), entry)?.listId?.toString()
            OutboxKind.DeleteItem -> decode(ItemDeletionPayload.serializer(), entry)?.listId
            else -> null
        }

    fun visitId(entry: OutboxEntryEntity): String? =
        when (entry.kind()) {
            OutboxKind.CreateVisit, OutboxKind.CloseVisit -> entry.entityId
            OutboxKind.InsertChecks -> decode(CheckPayload.serializer(), entry)?.visitId
            else -> null
        }

    private fun <T> decode(
        serializer: kotlinx.serialization.KSerializer<T>,
        entry: OutboxEntryEntity,
    ): T? =
        try {
            OutboxCoding.decode(serializer, entry.payload)
        } catch (_: SerializationException) {
            null
        } catch (_: IllegalArgumentException) {
            // Identifiant illisible dans la charge utile.
            null
        }
}

/** L'horodatage part tel quel, et le serveur le refuse s'il est trop loin dans le futur. */
val OutboxKind.carriesDeviceTime: Boolean
    get() =
        when (this) {
            OutboxKind.CreateVisit, OutboxKind.InsertChecks, OutboxKind.CloseVisit -> true
            OutboxKind.UpsertList, OutboxKind.DeleteList, OutboxKind.UpsertItem, OutboxKind.DeleteItem -> false
        }

/** Horloge du serveur, lue dans l'en-tête `Date` : aucune migration, et toute réponse en porte un. */
data class ServerClock(
    val serverNow: Instant,
    val deviceNow: Instant,
) {
    /**
     * Décalage à ôter à toutes les dates d'une visite, `null` si la plus récente n'est pas trop loin dans le futur.
     *
     * Un seul décalage garde l'ordre des coches. Il vaut l'avance mesurée, au moins de quoi ramener la plus récente
     * à l'heure du serveur : l'horloge a pu être remise à l'heure entre-temps, l'avance mesurée est alors nulle.
     */
    fun shift(forLatest: Instant): Duration? {
        if (forLatest <= serverNow + FUTURE_MARGIN) return null
        return maxOf(deviceNow - serverNow, forLatest - serverNow)
    }

    companion object {
        /** Marge sous les 5 min de `guard_visit` et `guard_check` (en-tête arrondi à la seconde, trajet compris). */
        val FUTURE_MARGIN: Duration = 240.seconds
    }
}
