package fr.parcourses.core.data.repository

import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.CheckEntity
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.VisitEntity
import kotlin.time.Duration
import kotlin.time.Duration.Companion.ZERO
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Ce qu'une coche désigne : produit du catalogue ou catégorie (`productId` xor `categoryId`, #8 §2.6). */
sealed interface CheckSubject {
    data class Product(
        val id: String,
    ) : CheckSubject

    data class Category(
        val id: String,
    ) : CheckSubject
}

/**
 * Visites et coches (`VisitRepository` d'iOS). Les écritures passent par la base **et** la file d'envoi dans une
 * seule transaction. Une visite ne part au serveur qu'avec sa première coche : sans coche, elle reste locale et
 * [closeVisit] la supprime (#9 §5.5).
 */
@Suppress("TooManyFunctions")
interface VisitRepository {
    suspend fun visit(id: String): VisitEntity?

    /** Visite ouverte, la plus récente : sert à la reprise au lancement. */
    suspend fun openVisit(): VisitEntity?

    /**
     * Une seule visite reste ouverte. Même liste et même magasin, et une activité il y a moins de [staleAfter] : la
     * visite existante est renvoyée. Sinon toute visite ouverte est d'abord abandonnée (voir [abandonVisit] : close
     * **à sa dernière coche**, jamais à [at], qui allongerait la visite de tout le temps passé ailleurs), puis une
     * visite neuve est créée. Une visite neuve commence sans introuvable : ceux de [listId] reviennent à acheter.
     */
    suspend fun startVisit(
        storeId: String,
        listId: String,
        listWasSorted: Boolean,
        at: Instant,
        staleAfter: Duration = Duration.INFINITE,
    ): VisitEntity

    /** Dernière activité d'une visite : sa dernière coche, sinon son début. `null` si elle n'existe pas. */
    suspend fun lastActivity(visitId: String): Instant?

    /**
     * Coche l'article et ajoute la coche dans une seule transaction : l'un ne va pas sans l'autre. Un article déjà
     * coché est refusé ([RepositoryException.AlreadyChecked]).
     * `list_items.checked_at` est écrit en plus de `checks` (le détail est partagé avec les autres appareils).
     * [sendAfter] : durée pendant laquelle la coche reste annulable sans jamais partir au serveur.
     */
    suspend fun checkItem(
        visitId: String,
        itemId: String,
        subject: CheckSubject,
        checkedAt: Instant,
        sendAfter: Duration = ZERO,
    ): CheckEntity

    /** Décoche l'article et retire la coche si elle n'est pas partie, dans une seule transaction. */
    suspend fun uncheckItem(
        itemId: String,
        checkId: String?,
        at: Instant,
    )

    /** Retire une coche pas encore partie ; `false` sans rien changer si elle a déjà été envoyée. */
    suspend fun removeCheck(id: String): Boolean

    /** Coches d'une visite, dans l'ordre chronologique. */
    suspend fun checks(visitId: String): List<CheckEntity>

    /**
     * Clôt la visite, sans effet si elle l'est déjà. Sans aucune coche, elle est supprimée et jamais envoyée :
     * renvoie alors `false`.
     */
    suspend fun closeVisit(
        id: String,
        at: Instant,
    ): Boolean

    /**
     * Clôt une visite quittée sans « Terminer » (restée ouverte trop longtemps, liste disparue) : à sa dernière coche,
     * supprimée si elle n'en a aucune. Personne n'a répondu à « garder ou retirer » : la réponse par défaut, garder,
     * s'applique, et les articles introuvables (non cochés) de sa liste reviennent à acheter.
     *
     * Sans effet, et sans erreur, si la visite n'existe plus (supprimée faute de coche, renommée par une reprise de
     * compte), si elle est déjà close, ou si sa dernière activité date de moins de [staleAfter] avant [at] : relue
     * dans la transaction, une visite redevenue active entre-temps reste ouverte. Renvoie `true` si cet appel l'a
     * close ou supprimée.
     */
    suspend fun abandonVisit(
        id: String,
        at: Instant,
        staleAfter: Duration = ZERO,
    ): Boolean
}

/** Implémentation Room. [onEnqueue] réveille la synchronisation après chaque transaction qui allonge la file. */
@Suppress("TooManyFunctions")
class RoomVisitRepository(
    private val db: ParcoursesDatabase,
    private val queue: OutboxQueue = OutboxQueue(db.outbox()),
    private val onEnqueue: () -> Unit = {},
    private val newId: () -> String = { Uuid.random().toString() },
) : VisitRepository {
    override suspend fun visit(id: String): VisitEntity? = db.visits().get(id)

    override suspend fun openVisit(): VisitEntity? = db.visits().getOpen().firstOrNull()

    override suspend fun startVisit(
        storeId: String,
        listId: String,
        listWasSorted: Boolean,
        at: Instant,
        staleAfter: Duration,
    ): VisitEntity {
        var enqueued = false
        val visit =
            db.withWriteTransaction {
                var reused: VisitEntity? = null
                for (open in db.visits().getOpen()) {
                    val same = open.storeId == storeId && open.listId == listId
                    if (same && reused == null && at - activityOf(open) < staleAfter) {
                        reused = open
                    } else {
                        enqueued = abandon(open) || enqueued
                    }
                }
                // Rien en file : la création part avec la première coche (#9 §5.5).
                reused
                    ?: VisitEntity(
                        id = newId(),
                        storeId = storeId,
                        listId = listId,
                        listWasSorted = listWasSorted,
                        startedAt = at,
                    ).also {
                        // Introuvables laissés par une visite close sans décision (expirée puis processus tué).
                        db.items().clearNotFound(listId)
                        db.visits().upsert(it)
                    }
            }
        if (enqueued) onEnqueue()
        return visit
    }

    override suspend fun lastActivity(visitId: String): Instant? = db.visits().get(visitId)?.let { activityOf(it) }

    private suspend fun activityOf(visit: VisitEntity): Instant =
        db.checks().getByVisit(visit.id).maxOfOrNull { it.checkedAt } ?: visit.startedAt

    override suspend fun checkItem(
        visitId: String,
        itemId: String,
        subject: CheckSubject,
        checkedAt: Instant,
        sendAfter: Duration,
    ): CheckEntity {
        val check =
            db.withWriteTransaction {
                requireUncheckedItem(itemId)
                val visit = requireOpenVisit(visitId)
                val isFirst = db.checks().getByVisit(visitId).isEmpty()
                val check =
                    CheckEntity(
                        id = newId(),
                        visitId = visitId,
                        itemId = itemId,
                        productId = (subject as? CheckSubject.Product)?.id,
                        categoryId = (subject as? CheckSubject.Category)?.id,
                        checkedAt = checkedAt,
                    )
                db.checks().upsert(check)
                val notBefore = if (sendAfter > ZERO) checkedAt + sendAfter else null
                if (isFirst) queue.enqueueCreation(visit, visit.listId, checkedAt, notBefore)
                queue.enqueueInsertion(check, checkedAt, notBefore)
                write(checkedAt = checkedAt, itemId = itemId, at = checkedAt)
                check
            }
        onEnqueue()
        return check
    }

    override suspend fun uncheckItem(
        itemId: String,
        checkId: String?,
        at: Instant,
    ) {
        db.withWriteTransaction {
            requireWritableItem(itemId)
            if (checkId != null) deleteUnsentCheck(checkId)
            write(checkedAt = null, itemId = itemId, at = at)
        }
        onEnqueue()
    }

    override suspend fun removeCheck(id: String): Boolean = db.withWriteTransaction { deleteUnsentCheck(id) }

    override suspend fun checks(visitId: String): List<CheckEntity> = db.checks().getByVisit(visitId)

    override suspend fun closeVisit(
        id: String,
        at: Instant,
    ): Boolean {
        val enqueued =
            db.withWriteTransaction {
                if (db.visits().get(id) == null) throw RepositoryException.NotFound(id)
                close(id, at)
            }
        if (enqueued) onEnqueue()
        return enqueued || db.visits().get(id) != null
    }

    override suspend fun abandonVisit(
        id: String,
        at: Instant,
        staleAfter: Duration,
    ): Boolean {
        var abandoned = false
        val enqueued =
            db.withWriteTransaction {
                val visit =
                    db.visits().get(id)?.takeIf { open ->
                        open.endedAt == null && (staleAfter <= ZERO || at - activityOf(open) >= staleAfter)
                    }
                abandoned = visit != null
                visit != null && abandon(visit)
            }
        if (enqueued) onEnqueue()
        return abandoned
    }

    /**
     * À appeler dans une transaction. Clôture sans décision, à la dernière coche : « garder » par défaut, donc les
     * introuvables de la liste reviennent à acheter (#54, M3). `true` si une clôture a été mise en file.
     */
    private suspend fun abandon(visit: VisitEntity): Boolean {
        if (visit.endedAt != null) return false
        db.items().clearNotFound(visit.listId)
        return close(visit.id, activityOf(visit))
    }

    /** `true` si une clôture a été mise en file. Une visite sans coche est supprimée, une visite close est laissée. */
    private suspend fun close(
        id: String,
        at: Instant,
    ): Boolean {
        val open = db.visits().get(id)?.takeIf { it.endedAt == null } ?: return false
        val hasChecks = db.checks().getByVisit(open.id).isNotEmpty()
        if (hasChecks) {
            db.visits().close(id, at)
            queue.enqueueClosure(id, at, at)
        } else {
            db.visits().delete(id)
        }
        return hasChecks
    }

    /**
     * À appeler dans une transaction. Plus d'entrée en attente : la coche est partie, ou abandonnée, et le serveur
     * ne sait pas la retirer.
     */
    private suspend fun deleteUnsentCheck(id: String): Boolean {
        val check = db.checks().get(id) ?: return false
        val sent = db.outbox().cancelPending(id, setOf(OutboxKind.InsertChecks)) == null
        if (!sent) {
            // Sans autre coche, la visite ne doit pas partir : elle ne partirait que vide.
            if (db.checks().getByVisit(check.visitId).all { it.id == id }) {
                db.outbox().cancelPending(check.visitId, setOf(OutboxKind.CreateVisit))
            }
            db.checks().delete(id)
        }
        return !sent
    }

    private suspend fun write(
        checkedAt: Instant?,
        itemId: String,
        at: Instant,
    ) {
        db.items().setChecked(itemId, checkedAt, at)
        queue.enqueueUpsert(requireNotNull(db.items().get(itemId)), at)
    }

    /** Un double événement ne doit pas compter deux passages devant le même rayon. */
    private suspend fun requireUncheckedItem(id: String) {
        if (requireWritableItem(id).checkedAt != null) throw RepositoryException.AlreadyChecked(id)
    }

    private suspend fun requireOpenVisit(id: String): VisitEntity {
        val visit = db.visits().get(id) ?: throw RepositoryException.NotFound(id)
        if (visit.endedAt != null) throw RepositoryException.VisitClosed(id)
        return visit
    }

    private suspend fun requireWritableItem(id: String): ListItemEntity {
        val item = db.items().get(id) ?: throw RepositoryException.NotFound(id)
        if (db.lists().get(item.listId)?.deletedAt != null) throw RepositoryException.ListDeleted(item.listId)
        return item
    }
}
