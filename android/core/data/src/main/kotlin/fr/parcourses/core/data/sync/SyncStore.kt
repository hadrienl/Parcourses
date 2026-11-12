package fr.parcourses.core.data.sync

import android.util.Log
import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.CheckPayload
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.outbox.OutboxDependencies
import fr.parcourses.core.data.outbox.ServerClock
import fr.parcourses.core.data.outbox.VisitClosePayload
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.ListItemEntity
import fr.parcourses.core.database.entity.OutboxEntryEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.CategoryMap
import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.VisitInsert
import kotlin.time.Duration
import kotlin.time.Instant

/** Ce qu'il faut savoir d'un article pour le créer localement à la descente. */
data class PulledItemClassification(
    val normalizedName: String,
    val categoryId: String,
)

/** Résultat d'une fusion descendante. */
class PullMerge {
    var changed = false
        internal set

    /** Plus grande date sûre pour le curseur : jamais au-delà d'une ligne sautée. */
    var cursor: Instant? = null
        private set
    private var oldestSkipped: Instant? = null

    internal fun skip(date: Instant) {
        oldestSkipped = oldestSkipped?.let { minOf(it, date) } ?: date
    }

    internal fun finish(dates: List<Instant>) {
        cursor = oldestSkipped ?: dates.maxOrNull()
    }
}

/**
 * Accès Room de la synchronisation. N'alloue jamais de `sequence` : les entrées ne sont ajoutées que par
 * `OutboxQueue`, dans la transaction de l'écriture qu'elles accompagnent.
 */
@Suppress("TooManyFunctions")
class SyncStore(
    private val db: ParcoursesDatabase,
) {
    private val outbox get() = db.outbox()

    // region File

    /**
     * Première entrée due dont aucune dépendance antérieure n'attend. Les coches d'une visite sont regroupées,
     * sauf si [singleChecks] contient la visite : un lot refusé est renvoyé ligne à ligne pour isoler la fautive.
     */
    @Suppress("LoopWithTooManyJumpStatements", "ReturnCount") // port d'iOS : une garde par cas, gardes
    suspend fun nextWork(
        now: Instant,
        singleChecks: Set<String> = emptySet(),
    ): OutboxWork? {
        val blocked = mutableSetOf<String>()
        for (entry in outbox.pending()) {
            val kind = entry.kind()
            val dependency = OutboxDependencies.dependency(entry)
            if (kind == null || dependency == null) {
                // Écrite par une autre version de l'app : la rejouer ne changerait rien.
                outbox.setState(entry.id, SyncState.FAILED, "entrée illisible")
                Log.e(TAG, "Entrée de file illisible abandonnée")
                continue
            }
            if (blocked.any { it in dependency.waits } || entry.nextAttemptAt > now) {
                blocked += dependency.blocks
                continue
            }
            val visitId = OutboxDependencies.visitId(entry)
            if (kind == OutboxKind.InsertChecks && visitId != null && visitId !in singleChecks) {
                return checksBatch(entry, visitId, now)
            }
            return work(listOf(entry), kind)
        }
        return null
    }

    /** Liste d'un article ou d'une visite en file si elle existe encore et n'a pas été reçue par le serveur. */
    @Suppress("ReturnCount") // port d'iOS : gardes de sortie anticipée
    suspend fun unsentListId(work: OutboxWork): String? {
        val payload = work.payloads.firstOrNull() ?: return null
        val listId =
            when (work.kind) {
                OutboxKind.UpsertItem -> {
                    runCatching {
                        OutboxCoding.decode(
                            ListItemUpsert.serializer(),
                            payload,
                        )
                    }.getOrNull()?.listId?.toString()
                }

                OutboxKind.CreateVisit -> {
                    runCatching {
                        OutboxCoding.decode(
                            VisitInsert.serializer(),
                            payload,
                        )
                    }.getOrNull()?.listId?.toString()
                }

                else -> {
                    null
                }
            } ?: return null
        val list = db.lists().get(listId) ?: return null
        return if (list.deletedAt == null && list.syncState == SyncState.PENDING) listId else null
    }

    /** Prochaine échéance future d'une entrée en attente. */
    suspend fun nextDueDate(after: Instant): Instant? =
        outbox
            .pending()
            .map { it.nextAttemptAt }
            .filter { it > after }
            .minOrNull()

    suspend fun pendingCount(): Int = outbox.pendingCount()

    /**
     * Une entrée absente a été remplacée pendant l'envoi : rien à faire, sa remplaçante partira.
     *
     * Sauf une création de visite annulée pendant l'envoi (dernière coche retirée) : le serveur a reçu la visite
     * quand même. Marquée reçue, elle sera close au lieu d'être supprimée en local (#62).
     */
    suspend fun complete(work: OutboxWork) =
        db.withWriteTransaction {
            val entities = mutableListOf<String>()
            for (id in work.entryIds) {
                val entry = outbox.get(id) ?: continue
                entities += entry.entityId
                outbox.delete(id)
            }
            if (work.kind == OutboxKind.CreateVisit && entities.isEmpty()) entities += work.entityId
            val pending = pendingEntityIds()
            for (entityId in entities) applyToEntity(work.kind, entityId, SyncState.SYNCED, pending)
        }

    /** Erreur définitive : journalisée, plus jamais rejouée (#9 §5.3). */
    suspend fun fail(
        work: OutboxWork,
        reason: String,
    ) {
        db.withWriteTransaction {
            val entities = mutableListOf<String>()
            for (id in work.entryIds) {
                val entry = outbox.get(id) ?: continue
                outbox.setState(id, SyncState.FAILED, reason)
                entities += entry.entityId
            }
            val pending = pendingEntityIds()
            for (entityId in entities) applyToEntity(work.kind, entityId, SyncState.FAILED, pending)
        }
        Log.e(TAG, "Entrée abandonnée (${work.kind.raw}) : $reason")
    }

    /** La visite n'a pas pu être créée : ses coches et sa clôture n'ont plus d'objet. */
    suspend fun failVisit(
        visitId: String,
        reason: String,
    ) {
        db.withWriteTransaction {
            for (entry in outbox.pending()) {
                if (OutboxDependencies.visitId(entry) == visitId) outbox.setState(entry.id, SyncState.FAILED, reason)
            }
            // Ce qui est déjà arrivé au serveur le reste.
            for (check in db.checks().getByVisit(visitId)) {
                if (check.syncState == SyncState.PENDING) db.checks().setSyncState(check.id, SyncState.FAILED)
            }
            db.visits().get(visitId)?.let { visit ->
                if (visit.syncState == SyncState.PENDING) db.visits().setSyncState(visitId, SyncState.FAILED)
                if (visit.endSyncState == SyncState.PENDING) db.visits().setEndSyncState(visitId, SyncState.FAILED)
            }
        }
        Log.e(TAG, "Visite abandonnée : $reason")
    }

    suspend fun postpone(
        work: OutboxWork,
        attempts: Int,
        until: Instant,
        reason: String,
    ) {
        db.withWriteTransaction {
            for (id in work.entryIds) {
                val entry = outbox.get(id) ?: continue
                outbox.recordAttempt(id, attempts, until, reason, entry.serverFailingSince, entry.syncState)
            }
        }
    }

    /** Note la première erreur serveur de chaque entrée et renvoie la plus ancienne. */
    suspend fun markServerFailure(
        work: OutboxWork,
        now: Instant,
        reason: String,
    ): Instant =
        db.withWriteTransaction {
            var oldest = now
            for (id in work.entryIds) {
                val entry = outbox.get(id) ?: continue
                val since = entry.serverFailingSince ?: now
                outbox.recordAttempt(id, entry.attempts, entry.nextAttemptAt, reason, since, entry.syncState)
                oldest = minOf(oldest, since)
            }
            oldest
        }

    /**
     * Corrige les dates envoyées, jamais les dates locales. Toutes les entrées en attente de la visite reçoivent le
     * même décalage : création, coches de tous les lots et clôture gardent leur ordre. Vrai si une date était trop
     * loin dans le futur.
     */
    suspend fun correctClock(
        work: OutboxWork,
        clock: ServerClock,
    ): Boolean =
        db.withWriteTransaction {
            val first = work.entryIds.firstOrNull()?.let { outbox.get(it) }
            val visitId = first?.let(OutboxDependencies::visitId)
            if (visitId == null) {
                false
            } else {
                val entries = outbox.pending().filter { OutboxDependencies.visitId(it) == visitId }
                val shift = entries.mapNotNull(::sentDate).maxOrNull()?.let(clock::shift)
                if (shift != null) entries.forEach { shiftEntry(it, shift) }
                shift != null
            }
        }

    private suspend fun shiftEntry(
        entry: OutboxEntryEntity,
        shift: Duration,
    ) {
        val payload =
            when (entry.kind()) {
                OutboxKind.CreateVisit -> {
                    val row = OutboxCoding.decode(VisitInsert.serializer(), entry.payload)
                    OutboxCoding.encode(VisitInsert.serializer(), row.copy(startedAt = row.startedAt - shift))
                }

                OutboxKind.InsertChecks -> {
                    val row = OutboxCoding.decode(CheckPayload.serializer(), entry.payload)
                    OutboxCoding.encode(CheckPayload.serializer(), row.with(row.checkedAt - shift))
                }

                OutboxKind.CloseVisit -> {
                    val row = OutboxCoding.decode(VisitClosePayload.serializer(), entry.payload)
                    OutboxCoding.encode(VisitClosePayload.serializer(), row.copy(endedAt = row.endedAt - shift))
                }

                else -> {
                    null
                }
            }
        if (payload != null) outbox.setPayload(entry.id, payload)
    }

    private fun sentDate(entry: OutboxEntryEntity): Instant? =
        when (entry.kind()) {
            OutboxKind.CreateVisit -> OutboxCoding.decode(VisitInsert.serializer(), entry.payload).startedAt
            OutboxKind.InsertChecks -> OutboxCoding.decode(CheckPayload.serializer(), entry.payload).checkedAt
            OutboxKind.CloseVisit -> OutboxCoding.decode(VisitClosePayload.serializer(), entry.payload).endedAt
            else -> null
        }

    /**
     * Reprise prouvée après une panne : les lignes mises de côté repartent. Leur départ de panne reste :
     * une ligne vraiment fautive retourne de côté dès son échec, sans retenir la file.
     */
    suspend fun releaseParked(now: Instant) {
        db.withWriteTransaction {
            for (entry in outbox.pending()) {
                if (entry.serverFailingSince != null && entry.nextAttemptAt > now) outbox.setNextAttempt(entry.id, now)
            }
        }
    }

    /** La liste de la visite n'existe plus côté serveur : la visite repart sans elle. */
    suspend fun removeListFromCreation(work: OutboxWork) {
        val entry = work.entryIds.firstOrNull()?.let { outbox.get(it) } ?: return
        val row = OutboxCoding.decode(VisitInsert.serializer(), entry.payload)
        outbox.setPayload(entry.id, OutboxCoding.encode(VisitInsert.serializer(), row.copy(listId = null)))
    }

    // endregion

    // region Produits

    /** Articles à soumettre à `resolve_products`. L'écriture du résultat se fait par [ProductResolution.apply]. */
    suspend fun productCandidates(
        excluding: Map<String, String>,
        limit: Int,
    ): List<ProductCandidate> = ProductResolution.candidates(db, excluding, limit)

    // endregion

    // region Descente

    /**
     * La ligne serveur s'applique dès qu'aucune entrée n'attend pour cet id : le local partira sinon ensuite
     * (#9 §5.4). Aucune comparaison de dates : horloge du serveur et de l'appareil ne se comparent pas.
     */
    suspend fun mergeLists(rows: List<ListRow>): PullMerge =
        db.withWriteTransaction {
            val pending = pendingEntityIds()
            val merge = PullMerge()
            for (row in rows) {
                val id = row.id.toString()
                if (id in pending) {
                    merge.skip(row.updatedAt)
                    continue
                }
                val local = db.lists().get(id)
                when {
                    local == null -> {
                        db.lists().upsert(
                            ShoppingListEntity(id, row.name, row.createdAt, row.updatedAt, null, SyncState.SYNCED),
                        )
                        merge.changed = true
                    }

                    // Suppression déjà partie ou abandonnée : la ligne disparaîtra du serveur ou restera masquée.
                    local.deletedAt != null -> {
                        Unit
                    }

                    else -> {
                        merge.changed = merge.changed || local.name != row.name
                        db.lists().upsert(
                            local.copy(name = row.name, updatedAt = row.updatedAt, syncState = SyncState.SYNCED),
                        )
                    }
                }
            }
            merge.finish(rows.map { it.updatedAt })
            merge
        }

    /**
     * `categoryId`, `notFoundAt` et `position` sont locaux : ils ne sont calculés qu'à la création ou si le
     * libellé change.
     */
    suspend fun mergeItems(
        rows: List<ListItemRow>,
        classify: (String) -> PulledItemClassification,
    ): PullMerge =
        db.withWriteTransaction {
            val pending = pendingEntityIds()
            val merge = PullMerge()
            for (row in rows) {
                val id = row.id.toString()
                val listId = row.listId.toString()
                val list = db.lists().get(listId)
                when {
                    id in pending -> merge.skip(row.updatedAt)

                    // Parent pas encore arrivé : le curseur reste en arrière pour relire cette ligne.
                    list == null -> merge.skip(row.updatedAt)

                    list.deletedAt != null -> Unit

                    else -> mergeItem(row, id, listId, classify, merge)
                }
            }
            merge.finish(rows.map { it.updatedAt })
            merge
        }

    private suspend fun mergeItem(
        row: ListItemRow,
        id: String,
        listId: String,
        classify: (String) -> PulledItemClassification,
        merge: PullMerge,
    ) {
        val items = db.items()
        val productId = row.productId?.toString()
        val local = items.get(id)
        if (local == null) {
            val classification = classify(row.label)
            items.upsert(
                ListItemEntity(
                    id = id,
                    listId = listId,
                    label = row.label,
                    normalizedName = classification.normalizedName,
                    quantity = row.quantity,
                    productId = productId,
                    categoryId = productCategory(productId) ?: classification.categoryId,
                    checkedAt = row.checkedAt,
                    position = items.nextPosition(listId),
                    updatedAt = row.updatedAt,
                    syncState = SyncState.SYNCED,
                ),
            )
            merge.changed = true
            return
        }
        var updated = local
        if (local.label != row.label) {
            val classification = classify(row.label)
            updated =
                local.copy(
                    label = row.label,
                    normalizedName = classification.normalizedName,
                    categoryId = productCategory(productId) ?: classification.categoryId,
                )
            merge.changed = true
        }
        merge.changed = merge.changed || local.quantity != row.quantity || local.checkedAt != row.checkedAt ||
            local.productId != productId
        items.upsert(
            updated.copy(
                listId = listId,
                quantity = row.quantity,
                productId = productId,
                checkedAt = row.checkedAt,
                updatedAt = row.updatedAt,
                syncState = SyncState.SYNCED,
            ),
        )
    }

    /** `shared/categories/` fait foi : aucun id local n'est jamais supprimé ni ajouté ici. */
    suspend fun applyCategories(rows: List<CategoryRow>) {
        val map = CategoryMap(rows)
        db.withWriteTransaction {
            val dao = db.categories()
            for (category in dao.getAll()) {
                val remote = map.remoteId(category.slug)?.toInt()
                if (remote != null) dao.setRemoteId(category.slug, remote) else dao.clearRemoteId(category.slug)
            }
        }
    }

    /** Remplacement du cache. Une réponse vide ne l'efface pas : elle n'apprend rien sur le catalogue. */
    suspend fun replaceProducts(rows: List<RemoteProduct>) {
        if (rows.isEmpty()) return
        db.withWriteTransaction {
            val known =
                db
                    .categories()
                    .getAll()
                    .map { it.id }
                    .toSet()
            db.products().deleteAll()
            db.products().upsertAll(
                rows.map { row ->
                    // Serveur en avance sur le référentiel embarqué : pas de catégorie, le classifieur prend le relais.
                    val category = row.categorySlug?.takeIf { it in known }
                    ProductEntity(row.id.toString(), row.name, row.normalizedName, category)
                },
            )
        }
    }

    // endregion

    // region Outils

    private suspend fun pendingEntityIds(): Set<String> = outbox.pending().map { it.entityId }.toSet()

    private suspend fun productCategory(productId: String?): String? =
        productId?.let { db.products().get(it)?.categoryId }

    private fun work(
        entries: List<OutboxEntryEntity>,
        kind: OutboxKind,
    ) = OutboxWork(
        entryIds = entries.map { it.id },
        kind = kind,
        entityId = entries.first().entityId,
        payloads = entries.map { it.payload },
        attempts = entries.maxOf { it.attempts },
    )

    @Suppress("LoopWithTooManyJumpStatements") // port d'iOS : une garde par cas écarté
    private suspend fun checksBatch(
        first: OutboxEntryEntity,
        visitId: String,
        now: Instant,
    ): OutboxWork {
        val batch = mutableListOf<OutboxEntryEntity>()
        for (entry in outbox.pending()) {
            if (entry.sequence < first.sequence || OutboxDependencies.visitId(entry) != visitId) continue
            if (entry.kind() != OutboxKind.InsertChecks || entry.nextAttemptAt > now) continue
            if (batch.size >= MAX_CHECKS_PER_BATCH) break
            batch += entry
        }
        return work(batch, OutboxKind.InsertChecks)
    }

    /** [pending] : une entrée plus récente de la même entité garde celle-ci en attente. */
    private suspend fun applyToEntity(
        kind: OutboxKind,
        entityId: String,
        state: SyncState,
        pending: Set<String>,
    ) {
        val stillPending = entityId in pending
        when (kind) {
            OutboxKind.UpsertList -> {
                if (!stillPending) db.lists().setSyncState(entityId, state)
            }

            OutboxKind.UpsertItem -> {
                if (!stillPending) db.items().setSyncState(entityId, state)
            }

            OutboxKind.DeleteList -> {
                if (state == SyncState.SYNCED) {
                    // Le serveur a supprimé les articles en cascade : la suppression douce devient définitive.
                    db.items().deleteByList(entityId)
                    db.lists().delete(entityId)
                }
            }

            OutboxKind.DeleteItem -> {
                Unit
            }

            OutboxKind.CreateVisit -> {
                db.visits().setSyncState(entityId, state)
            }

            OutboxKind.InsertChecks -> {
                db.checks().setSyncState(entityId, state)
            }

            OutboxKind.CloseVisit -> {
                db.visits().setEndSyncState(entityId, state)
            }
        }
    }

    // endregion

    companion object {
        private const val TAG = "SyncStore"

        /** Taille d'un insert groupé de coches (#9 §5.2). */
        const val MAX_CHECKS_PER_BATCH = 200
    }
}
