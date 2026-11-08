package fr.parcourses.core.data.sync

import androidx.room3.withWriteTransaction
import fr.parcourses.core.data.outbox.CheckPayload
import fr.parcourses.core.data.outbox.OutboxCoding
import fr.parcourses.core.data.outbox.OutboxQueue
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.OutboxKind
import fr.parcourses.core.database.entity.ProductEntity
import fr.parcourses.core.database.entity.SyncState
import fr.parcourses.core.network.dto.ProductResolutionRequest
import fr.parcourses.core.network.dto.ResolvedProductRow
import kotlin.time.Instant

/** Article saisi librement, sans produit : candidat à `resolve_products`. */
data class ProductCandidate(
    val itemId: String,
    /** Libellé envoyé : la réponse ne s'applique que s'il n'a pas changé entre-temps. */
    val label: String,
    val categorySlug: String?,
) {
    val request: ProductResolutionRequest get() = ProductResolutionRequest(name = label, categorySlug = categorySlug)
}

/** Produit obtenu pour un candidat. */
data class ProductMatch(
    val candidate: ProductCandidate,
    val productId: String,
    val name: String,
    val normalizedName: String,
    val categorySlug: String?,
) {
    companion object {
        /** `null` si le serveur n'a ni trouvé ni créé de produit. */
        fun of(
            candidate: ProductCandidate,
            row: ResolvedProductRow,
        ): ProductMatch? {
            val id = row.id ?: return null
            val name = row.name ?: return null
            val normalized = row.normalizedName ?: return null
            return ProductMatch(candidate, id.toString(), name, normalized, row.categorySlug)
        }
    }
}

/**
 * Apprentissage sans catalogue : un article saisi librement reçoit le produit partagé de son libellé, pour que
 * ses coches nourrissent le graphe du magasin. Port de `ProductResolution` d'iOS.
 */
object ProductResolution {
    /**
     * Articles sans produit, hors listes supprimées. [attempted] : libellé déjà soumis pour cet article.
     * Ordre total (date, puis id) : les mêmes articles partent d'abord.
     */
    suspend fun candidates(
        db: ParcoursesDatabase,
        attempted: Map<String, String>,
        limit: Int,
    ): List<ProductCandidate> {
        val deletedLists = db.lists().deletedIds().toSet()
        val slugs = db.categories().getAll().associate { it.id to it.slug }
        return db
            .items()
            .withoutProduct()
            .asSequence()
            .filter { it.listId !in deletedLists && attempted[it.id] != it.label && it.label.isNotBlank() }
            .take(limit)
            .map { ProductCandidate(it.id, it.label, slugs[it.categoryId] ?: it.categoryId) }
            .toList()
    }

    /**
     * L'article reçoit son produit et repart au serveur ; ses coches encore en file désignent désormais le produit
     * au lieu de la catégorie. La catégorie locale de l'article ne change pas : il resterait sinon à sa place à
     * l'écran jusqu'au prochain tri. Vrai si une donnée affichée a changé.
     */
    suspend fun apply(
        db: ParcoursesDatabase,
        matches: List<ProductMatch>,
        at: Instant,
        queue: OutboxQueue = OutboxQueue(db.outbox()),
    ): Boolean =
        db.withWriteTransaction {
            val localIds = db.categories().getAll().associate { it.slug to it.id }
            var changed = false
            for (match in matches) {
                val item = db.items().get(match.candidate.itemId)
                if (item == null || item.productId != null || item.label != match.candidate.label) continue
                if (db.lists().get(item.listId)?.deletedAt != null) continue
                if (db.products().get(match.productId) == null) {
                    db.products().upsertAll(
                        listOf(
                            ProductEntity(
                                match.productId,
                                match.name,
                                match.normalizedName,
                                match.categorySlug?.let { localIds[it] },
                            ),
                        ),
                    )
                }
                val resolved = item.copy(productId = match.productId, syncState = SyncState.PENDING)
                db.items().upsert(resolved)
                queue.enqueueUpsert(resolved, at)
                redirectQueuedChecks(db, item.id, match.productId)
                changed = true
            }
            changed
        }

    private suspend fun redirectQueuedChecks(
        db: ParcoursesDatabase,
        itemId: String,
        productId: String,
    ) {
        for (check in db.checks().pendingWithoutProduct(itemId)) {
            val queued = db.outbox().pendingFor(check.id).filter { it.kind() == OutboxKind.InsertChecks }
            // Plus en file : la coche est partie ou abandonnée, le serveur la garde telle quelle.
            if (queued.isEmpty()) continue
            db.checks().upsert(check.copy(productId = productId, categoryId = null))
            for (entry in queued) {
                val payload = OutboxCoding.decode(CheckPayload.serializer(), entry.payload)
                db.outbox().setPayload(
                    entry.id,
                    OutboxCoding.encode(CheckPayload.serializer(), payload.withProduct(productId)),
                )
            }
        }
    }
}
