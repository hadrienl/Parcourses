package fr.parcourses.core.data.sync

import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.SyncState
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Anciens identifiants vers nouveaux, pour les écrans ouverts. */
data class IdentifierRemap(
    val identifiers: Map<String, String>,
) {
    operator fun get(id: String): String = identifiers[id] ?: id
}

/**
 * Reprise après perte de session : le nouveau compte anonyme ne voit aucune ligne de l'ancien, et un même
 * identifiant y serait ignoré en silence (`on conflict do nothing`). Tout change donc d'identifiant, et tout repart
 * sauf les visites reçues et closes (elles seraient réapprises dans le graphe partagé).
 *
 * Une seule transaction : tout ou rien. Rejouable : tant que le compte n'est pas acquitté
 * (`RemoteGateway.acknowledgeAccount`), aucun envoi n'a lieu et ces identifiants n'existent nulle part ;
 * recommencer n'a donc aucun effet visible. Port d'`AccountRekey` d'iOS.
 */
class AccountRekey(
    private val db: ParcoursesDatabase,
    private val queue: OutboxQueue = OutboxQueue(db.outbox()),
    private val newId: () -> String = { Uuid.random().toString() },
) {
    @Suppress("LongMethod", "CyclomaticComplexMethod")
    suspend fun run(now: Instant): IdentifierRemap =
        db.withWriteTransaction {
            val visits = db.visits().getAll()
            val received =
                visits
                    .filter { it.syncState == SyncState.SYNCED && it.endSyncState == SyncState.SYNCED }
                    .map { it.id }
                    .toSet()
            val entries = db.outbox().all()
            // Coche retenue pendant l'annulation : l'envoi reste retenu, sinon elle deviendrait immuable trop tôt.
            val held = mutableMapOf<String, Instant>()
            for (entry in entries) {
                if (entry.syncState == SyncState.PENDING &&
                    entry.nextAttemptAt > now
                ) {
                    held[entry.entityId] = entry.nextAttemptAt
                }
            }
            // Suppressions comprises : le nouveau compte n'a rien à supprimer.
            entries.forEach { db.outbox().delete(it.id) }

            val identifiers = mutableMapOf<String, String>()
            val fresh: (String) -> String = { old -> newId().also { identifiers[old] = it } }

            val lists = db.lists().getAll()
            val items = db.items().getAll()
            // Liste supprimée par l'utilisateur : sa suppression s'achève ici, elle ne doit pas réapparaître.
            val deleted = lists.filter { it.deletedAt != null }.map { it.id }.toSet()
            items.filter { it.listId in deleted }.forEach { db.items().delete(it.id) }
            deleted.forEach { db.lists().delete(it) }

            val alive = mutableSetOf<String>()
            for (list in lists.filter { it.deletedAt == null }) {
                db.lists().delete(list.id)
                val moved = list.copy(id = fresh(list.id), syncState = SyncState.PENDING)
                db.lists().upsert(moved)
                alive += moved.id
                queue.enqueueUpsert(moved, now)
            }
            for (item in items.filter { it.listId !in deleted }.sortedWith(compareBy({ it.position }, { it.id }))) {
                db.items().delete(item.id)
                val newId = fresh(item.id)
                val listId = identifiers[item.listId]
                if (listId == null) {
                    // Orphelin : sans liste à envoyer, le serveur le refuserait. Il reste en local, sans entrée.
                    db.items().upsert(item.copy(id = newId, syncState = SyncState.FAILED))
                    continue
                }
                val moved = item.copy(id = newId, listId = listId, syncState = SyncState.PENDING)
                db.items().upsert(moved)
                queue.enqueueUpsert(moved, now)
            }

            val checksByVisit = db.checks().getAll().groupBy { it.visitId }
            for (visit in visits) {
                val own = checksByVisit[visit.id].orEmpty()
                db.visits().delete(visit.id)
                val newVisitId = fresh(visit.id)
                val listId = identifiers[visit.listId] ?: visit.listId
                // Reçue et close : elle a pu nourrir le graphe partagé, la renvoyer l'y apprendrait deux fois.
                // Elle reste en local. Visite ouverte ou clôture non reçue : jamais apprise, elle repart en entier.
                val keepLocal = visit.id in received
                val state = if (keepLocal) SyncState.SYNCED else SyncState.PENDING
                val moved = visit.copy(id = newVisitId, listId = listId, syncState = state, endSyncState = state)
                db.visits().upsert(moved)
                // Sans coche, une visite reste locale (#9 §5.5). Elle partira avec sa première coche.
                val resend = !keepLocal && own.isNotEmpty()
                // Dans l'ordre des dépendances : création, coches, puis clôture.
                if (resend) queue.enqueueCreation(moved, listId.takeIf { it in alive }, now, notBefore = held[visit.id])
                for (check in own) {
                    db.checks().delete(check.id)
                    val rekeyed =
                        check.copy(
                            id = fresh(check.id),
                            visitId = newVisitId,
                            itemId = identifiers[check.itemId] ?: check.itemId,
                            syncState = if (keepLocal) check.syncState else SyncState.PENDING,
                        )
                    db.checks().upsert(rekeyed)
                    if (resend) queue.enqueueInsertion(rekeyed, now, notBefore = held[check.id])
                }
                // Après les coches : la RLS refuse toute coche sur une visite close.
                if (resend) moved.endedAt?.let { queue.enqueueClosure(moved.id, it, now) }
            }
            IdentifierRemap(identifiers.toMap())
        }
}
