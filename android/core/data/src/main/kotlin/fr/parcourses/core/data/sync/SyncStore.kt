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
import fr.parcourses.core.database.entity.ListParticipantEntity
import fr.parcourses.core.database.entity.OutboxEntryEntity
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.ShoppingListEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.database.entity.syncedOnce
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.CategoryMap
import fr.parcourses.core.network.dto.CategoryRow
import fr.parcourses.core.network.dto.ListItemRow
import fr.parcourses.core.network.dto.ListItemUpsert
import fr.parcourses.core.network.dto.ListMemberRow
import fr.parcourses.core.network.dto.ListRow
import fr.parcourses.core.network.dto.ListSharing
import fr.parcourses.core.network.dto.ProfileRow
import fr.parcourses.core.network.dto.RemoteProduct
import fr.parcourses.core.network.dto.VisitInsert
import kotlin.time.Duration
import kotlin.time.Instant

/** Mon rôle sur une liste a changé (#87, lot 87.6). */
data class RoleChange(
    val listId: String,
    val from: ListRole,
    val to: ListRole,
)

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
@Suppress("TooManyFunctions", "LargeClass") // une méthode par opération de la file et de la descente
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
    suspend fun mergeLists(
        rows: List<ListRow>,
        me: String? = null,
    ): PullMerge =
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
                            ShoppingListEntity(
                                id,
                                row.name,
                                row.createdAt,
                                row.updatedAt,
                                null,
                                SyncState.SYNCED,
                                ownerId = row.ownerId.toString(),
                                // Liste d'un autre : lecture seule jusqu'à ce que les membres disent mon rôle.
                                role =
                                    if (me == null ||
                                        row.ownerId.toString() == me
                                    ) {
                                        ListRole.Owner
                                    } else {
                                        ListRole.Viewer
                                    },
                            ),
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
                            // Les deux dates du serveur : égales tant que la liste n'a pas changé (règle `skip` du
                            // vecteur 008 à la reprise de compte).
                            local.copy(
                                name = row.name,
                                createdAt = row.createdAt,
                                updatedAt = row.updatedAt,
                                syncState = SyncState.SYNCED,
                                ownerId = row.ownerId.toString(),
                            ),
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
                    isOnServer = true,
                    updatedBy = row.updatedBy?.toString(),
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
                isOnServer = true,
                updatedBy = row.updatedBy?.toString(),
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

    /**
     * Remplacement du cache par le catalogue publié (#69). Une réponse vide ne l'efface que si le catalogue était
     * lisible ([catalogReadable] : les catégories de la même passe sont arrivées) : plus aucun produit n'est publié, et
     * les noms téléchargés avant ne doivent pas rester sur l'appareil. Sinon elle n'apprend rien sur le catalogue.
     */
    suspend fun replaceProducts(
        rows: List<RemoteProduct>,
        catalogReadable: Boolean,
    ) {
        if (rows.isEmpty() && !catalogReadable) return
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

    // region Comptes et partage (#87)

    suspend fun item(id: String): ListItemEntity? = db.items().get(id)

    suspend fun list(id: String): ShoppingListEntity? = db.lists().get(id)

    /**
     * Réconciliation des listes à la descente (vecteur `005`) : les listes déjà synchronisées que le serveur ne laisse
     * plus lire quittent l'appareil, articles et entrées de file comprises. Renvoie le plan, dont les listes à
     * descendre entièrement. Les visites gardent leur liste : leur création repartira sans elle (`42501`).
     */
    suspend fun reconcile(listIds: Collection<String>): ListReconciliationPlan =
        db.withWriteTransaction {
            val local = db.lists().getAll().map { LocalListState(it.id, it.syncedOnce) }
            val plan = SyncDecisions.reconcileLists(local, listIds)
            removeListsLocked(plan.remove)
            plan
        }

    /** Retire ces listes de l'appareil, avec leurs articles et toutes leurs entrées de file. */
    suspend fun removeLists(ids: Collection<String>) = db.withWriteTransaction { removeListsLocked(ids) }

    /**
     * Pierres tombales descendues (vecteur `006`) : les articles locaux de même id sont supprimés, entrées de file
     * comprises (la suppression gagne). Vrai si un article a disparu.
     */
    suspend fun merge(tombstones: Collection<String>): Boolean =
        db.withWriteTransaction {
            val doomed = SyncDecisions.applyTombstones(db.items().allIds(), tombstones)
            deleteItemsLocked(doomed)
            doomed.isNotEmpty()
        }

    /**
     * Réconciliation complète d'une liste (vecteur `007`, `fullReconcile`) : un article local déjà arrivé au serveur
     * et absent de [serverIds] a été supprimé ailleurs. Vrai si un article a disparu.
     */
    suspend fun reconcileItems(
        listId: String,
        serverIds: Collection<String>,
    ): Boolean =
        db.withWriteTransaction {
            val alive = serverIds.toSet()
            val doomed =
                db
                    .items()
                    .getByList(listId)
                    .filter { it.isOnServer && it.id !in alive }
                    .map { it.id }
            deleteItemsLocked(doomed)
            doomed.isNotEmpty()
        }

    /** Listes à réconcilier article par article : déjà synchronisées, non supprimées. */
    suspend fun syncedListIds(): List<String> =
        db
            .lists()
            .getAll()
            .filter { it.deletedAt == null && it.syncedOnce }
            .map { it.id }

    /**
     * `refreshAccess` (#87 §6.4) : les entrées en attente de la liste et de ses articles sont jetées, puis la liste
     * reprend exactement les articles du serveur ([rows], descente complète).
     */
    suspend fun replaceItems(
        listId: String,
        rows: List<ListItemRow>,
        classify: (String) -> PulledItemClassification,
        keepUnsent: Boolean = false,
        onDropped: (Int) -> Unit = {},
    ): PullMerge {
        var dropped = 0
        db.withWriteTransaction {
            // [keepUnsent] (liste à soi) : les articles jamais arrivés au serveur et leurs entrées restent.
            val unsent =
                if (keepUnsent) {
                    db
                        .items()
                        .getByList(
                            listId,
                        ).filter { !it.isOnServer }
                        .map { it.id }
                        .toSet()
                } else {
                    emptySet()
                }
            for (entry in outbox.all()) {
                if (entry.entityId in unsent) continue
                val tied =
                    when (entry.kind()) {
                        OutboxKind.UpsertList, OutboxKind.DeleteList -> entry.entityId == listId
                        OutboxKind.UpsertItem, OutboxKind.DeleteItem -> OutboxDependencies.listId(entry) == listId
                        else -> false
                    }
                if (tied) {
                    outbox.delete(entry.id)
                    dropped += 1
                }
            }
            val alive = rows.map { it.id.toString() }.toSet()
            for (item in db.items().getByList(listId)) {
                if (item.id !in alive && item.id !in unsent) db.items().delete(item.id)
            }
            db.lists().get(listId)?.takeIf { it.syncState != SyncState.SYNCED }?.let {
                db.lists().setSyncState(listId, SyncState.SYNCED)
            }
        }
        onDropped(dropped)
        return mergeItems(rows, classify)
    }

    /** Toutes les listes, supprimées comprises (noms des listes qu'une réconciliation va retirer). */
    suspend fun lists(): List<ShoppingListEntity> = db.lists().getAll()

    /**
     * Membres de toutes les listes (#87, lot 87.6), à la descente : les personnes de chaque liste partagée
     * (propriétaire compris) remplacent celles de l'appareil, et mon rôle est relu. Une liste jamais descendue reste à
     * soi, sans personne. Renvoie les rôles changés des listes déjà connues comme partagées (pas l'arrivée d'une
     * liste).
     */
    suspend fun replaceParticipants(
        members: List<ListMemberRow>,
        profiles: List<ProfileRow>,
        me: String?,
    ): List<RoleChange> =
        db.withWriteTransaction {
            val names = profiles.associate { it.userId.toString() to it.displayName }
            val byList = members.groupBy { it.listId.toString() }
            val known =
                db
                    .participants()
                    .all()
                    .filter { it.isMe }
                    .map { it.listId }
                    .toSet()
            val rows = mutableListOf<ListParticipantEntity>()
            val changes = mutableListOf<RoleChange>()
            for (list in db.lists().getAll()) {
                val owner = list.ownerId ?: continue
                val listMembers = byList[list.id].orEmpty()
                if (listMembers.isNotEmpty() ||
                    owner != me
                ) {
                    rows += participantsOf(list.id, owner, listMembers, names, me)
                }
                val role = me?.let { myRole(owner, listMembers, it) }
                if (role != null && role != list.role) {
                    db.lists().setRole(list.id, role)
                    if (list.id in known) changes += RoleChange(list.id, list.role, role)
                }
            }
            db.participants().deleteAll()
            db.participants().upsertAll(rows)
            changes
        }

    /** Personnes d'une liste partagée : son propriétaire, puis ses membres. */
    private fun participantsOf(
        listId: String,
        owner: String,
        members: List<ListMemberRow>,
        names: Map<String, String?>,
        me: String?,
    ): List<ListParticipantEntity> =
        listOf(ListParticipantEntity(listId, owner, names[owner], ListRole.Owner, owner == me)) +
            members.map { member ->
                val user = member.userId.toString()
                ListParticipantEntity(listId, user, names[user], member.role, user == me, member.createdAt)
            }

    /** Mon rôle sur une liste : propriétaire, celui de `list_members`, ou `null` si je n'y figure pas. */
    private fun myRole(
        owner: String,
        members: List<ListMemberRow>,
        me: String,
    ): ListRole? = if (owner == me) ListRole.Owner else members.firstOrNull { it.userId.toString() == me }?.role

    /** Réponse de `list_sharing` pour une liste : ses personnes et mon rôle. Renvoie le changement de rôle éventuel. */
    suspend fun applySharing(sharing: ListSharing): RoleChange? =
        db.withWriteTransaction {
            val listId = sharing.listId.toString()
            val list = db.lists().get(listId) ?: return@withWriteTransaction null
            db.participants().deleteByList(listId)
            val shared = sharing.members.isNotEmpty() || !sharing.owner.isMe
            if (shared) {
                db.participants().upsertAll(
                    sharing.participants.map {
                        ListParticipantEntity(
                            listId,
                            it.userId.toString(),
                            it.displayName,
                            it.role,
                            it.isMe,
                            it.joinedAt,
                        )
                    },
                )
            }
            if (list.role == sharing.role) return@withWriteTransaction null
            db.lists().setRole(listId, sharing.role)
            RoleChange(listId, list.role, sharing.role)
        }

    private suspend fun removeListsLocked(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val doomed = ids.toSet()
        for (entry in outbox.all()) {
            val listId =
                when (entry.kind()) {
                    OutboxKind.UpsertList, OutboxKind.DeleteList -> entry.entityId
                    OutboxKind.UpsertItem, OutboxKind.DeleteItem -> OutboxDependencies.listId(entry)
                    else -> null
                }
            if (listId in doomed) outbox.delete(entry.id)
        }
        for (id in doomed) {
            db.items().deleteByList(id)
            db.participants().deleteByList(id)
            db.lists().delete(id)
        }
        Log.i(TAG, "Listes retirées de l'appareil : ${doomed.size}")
    }

    private suspend fun deleteItemsLocked(ids: Collection<String>) {
        for (id in ids) {
            outbox.deleteAllFor(id)
            db.items().delete(id)
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
        changedFields = entries.first().changedFields,
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
                // Envoi accusé : l'article est sur le serveur, même si une modification plus récente attend.
                if (state == SyncState.SYNCED) db.items().markOnServer(entityId)
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
