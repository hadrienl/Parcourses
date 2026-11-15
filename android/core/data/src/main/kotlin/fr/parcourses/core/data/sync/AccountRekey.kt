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

/** Résultat d'une reprise : les nouveaux identifiants, et le nombre de listes renvoyées au nouveau compte. */
data class AccountRekeyResult(
    val remap: IdentifierRemap,
    val resentLists: Int,
)

/**
 * Reprise après un changement de compte (session perdue, connexion à un compte e-mail existant) : le nouveau compte
 * ne voit aucune ligne de l'ancien, et un même identifiant y serait ignoré en silence (`on conflict do nothing`).
 * Tout change donc d'identifiant, et tout repart sauf les visites reçues et closes (elles seraient réapprises dans le
 * graphe partagé).
 *
 * Sort de chaque liste (#87 §2.3, vecteur `008`, [SyncDecisions.rekeyPlan]) : une liste d'un autre propriétaire est
 * retirée de l'appareil sans être renvoyée (la descente la ramènera si le nouveau compte en est membre) ; une liste
 * vide jamais modifiée aussi. Un article dont le produit n'est pas dans le cache du catalogue publié part sans produit
 * (#69 : un produit privé de l'ancien compte a pu être purgé, `23503`) ; il sera résolu à nouveau.
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
    /** [previousAccountId] : compte auquel appartenaient les données locales (`SyncCursors.accountId`). */
    @Suppress("LongMethod", "CyclomaticComplexMethod")
    suspend fun run(
        now: Instant,
        previousAccountId: String? = null,
        previousWasEmail: Boolean = false,
    ): AccountRekeyResult =
        db.withWriteTransaction {
            // Ancien compte e-mail : ses données restent sous lui, sur le serveur ; rien ne part vers le nouveau
            // compte, tout quitte l'appareil (#87). Seul un ancien compte anonyme est repris.
            if (previousWasEmail) return@withWriteTransaction dropEverything()
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
            val counts = items.groupingBy { it.listId }.eachCount()
            val plans =
                lists.associate { list ->
                    val state =
                        RekeyListState(
                            ownerId = list.ownerId,
                            deleted = list.deletedAt != null,
                            itemCount = counts[list.id] ?: 0,
                            createdAt = list.createdAt,
                            updatedAt = list.updatedAt,
                        )
                    // Sans ancien compte connu, une liste au propriétaire connu n'est pas renvoyée (même règle qu'iOS).
                    list.id to SyncDecisions.rekeyPlan(previousAccountId.orEmpty(), state)
                }
            // Supprimée par l'utilisateur (sa suppression s'achève), d'un autre propriétaire, ou vide jamais modifiée :
            // retirée de l'appareil avec ses articles, jamais renvoyée.
            val deleted = plans.filterValues { it != RekeyPlan.Resend }.keys
            items.filter { it.listId in deleted }.forEach { db.items().delete(it.id) }
            deleted.forEach { db.lists().delete(it) }

            val alive = mutableSetOf<String>()
            for (list in lists.filter { it.id !in deleted }) {
                db.lists().delete(list.id)
                // Renvoyée au nouveau compte, qui en devient le propriétaire.
                val moved = list.copy(id = fresh(list.id), syncState = SyncState.PENDING, ownerId = null)
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
                    db.items().upsert(item.copy(id = newId, syncState = SyncState.FAILED, isOnServer = false))
                    continue
                }
                // Produit absent du catalogue publié : retiré, l'article sera résolu à nouveau pour le nouveau compte.
                val productId = item.productId?.takeIf { db.products().get(it) != null }
                val moved =
                    item.copy(
                        id = newId,
                        listId = listId,
                        productId = productId,
                        syncState = SyncState.PENDING,
                        isOnServer = false,
                    )
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
            AccountRekeyResult(IdentifierRemap(identifiers.toMap()), resentLists = alive.size)
        }

    private suspend fun dropEverything(): AccountRekeyResult {
        db.outbox().all().forEach { db.outbox().delete(it.id) }
        db.checks().getAll().forEach { db.checks().delete(it.id) }
        db.visits().getAll().forEach { db.visits().delete(it.id) }
        db.items().getAll().forEach { db.items().delete(it.id) }
        db.lists().getAll().forEach { db.lists().delete(it.id) }
        return AccountRekeyResult(IdentifierRemap(emptyMap()), resentLists = 0)
    }
}
