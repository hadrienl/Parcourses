package fr.parcourses.core.database.entity

import androidx.room3.ColumnInfo
import androidx.room3.Entity
import androidx.room3.Index
import androidx.room3.PrimaryKey
import kotlin.time.Instant

// Les identifiants UUID sont stockés en texte minuscule (règle de comparaison de #5).
// Les noms de propriétés reprennent ceux du schéma SwiftData iOS (SchemaV1 à V3) ; les écarts sont dans SYNC.md.

/** Liste de courses (`lists`). `owner_id` est posé par le serveur. */
@Entity(tableName = "lists")
data class ShoppingListEntity(
    @PrimaryKey val id: String,
    val name: String,
    val createdAt: Instant,
    val updatedAt: Instant,
    /** Suppression douce, le temps que le `DELETE` parte au serveur. */
    val deletedAt: Instant? = null,
    val syncState: SyncState = SyncState.PENDING,
)

/** Article d'une liste (`list_items`). `categoryId`, `notFoundAt` et `position` restent locaux. */
@Entity(
    tableName = "list_items",
    indices = [Index("listId"), Index("updatedAt"), Index("categoryId")],
)
data class ListItemEntity(
    @PrimaryKey val id: String,
    val listId: String,
    val label: String,
    val normalizedName: String,
    /** Texte libre, comme la colonne `quantity` du serveur. */
    val quantity: String? = null,
    val productId: String? = null,
    val categoryId: String,
    val checkedAt: Instant? = null,
    val notFoundAt: Instant? = null,
    val position: Int,
    val updatedAt: Instant,
    val syncState: SyncState = SyncState.PENDING,
)

/** Visite d'un magasin (`visits`). Création et clôture partent séparément. */
@Entity(tableName = "visits")
data class VisitEntity(
    @PrimaryKey val id: String,
    val storeId: String,
    val listId: String,
    val listWasSorted: Boolean,
    val startedAt: Instant,
    val endedAt: Instant? = null,
    val syncState: SyncState = SyncState.PENDING,
    /** État d'envoi de la clôture, indépendant de celui de la création. */
    val endSyncState: SyncState = SyncState.PENDING,
)

/** Coche horodatée (`checks`), immuable. `itemId` ne part pas au serveur. */
@Entity(
    tableName = "checks",
    indices = [Index("visitId"), Index("itemId"), Index("categoryId")],
)
data class CheckEntity(
    @PrimaryKey val id: String,
    val visitId: String,
    val itemId: String,
    /** `productId` xor `categoryId` : garanti par l'appelant à l'écriture. */
    val productId: String? = null,
    val categoryId: String? = null,
    val checkedAt: Instant,
    val syncState: SyncState = SyncState.PENDING,
)

/**
 * Magasin en cache. Aucune position n'est stockée, ni du magasin ni de l'utilisateur : pas de distance non plus
 * (`lastDistanceM` d'iOS, toujours vide, n'est volontairement pas repris).
 */
@Entity(tableName = "stores")
data class StoreEntity(
    @PrimaryKey val id: String,
    val name: String,
    val chain: String? = null,
    val address: String? = null,
    val lastUsedAt: Instant? = null,
    /** Le magasin a un rayon bio. Faux tant que le serveur n'a rien dit. */
    @ColumnInfo(defaultValue = "0") val organicAisle: Boolean = false,
)

/** Instantané du graphe d'un magasin, JSON brut remplacé d'un bloc (#9 §4.3). */
@Entity(
    tableName = "graph_snapshots",
    indices = [Index("fetchedAt")],
)
class GraphSnapshotEntity(
    @PrimaryKey val storeId: String,
    val snapshotVersion: Long,
    val paramsVersion: Long,
    val confidenceQ: Long,
    val fetchedAt: Instant,
    val payload: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        this === other ||
            (
                other is GraphSnapshotEntity &&
                    storeId == other.storeId &&
                    snapshotVersion == other.snapshotVersion &&
                    paramsVersion == other.paramsVersion &&
                    confidenceQ == other.confidenceQ &&
                    fetchedAt == other.fetchedAt &&
                    payload.contentEquals(other.payload)
            )

    override fun hashCode(): Int = 31 * storeId.hashCode() + payload.contentHashCode()

    override fun toString(): String = "GraphSnapshotEntity(storeId=$storeId, snapshotVersion=$snapshotVersion)"
}

/** Produit du catalogue en cache (`products`). */
@Entity(tableName = "products", indices = [Index("categoryId")])
data class ProductEntity(
    @PrimaryKey val id: String,
    val name: String,
    val normalizedName: String,
    /** Peut manquer : la colonne serveur `category_id` est nullable. */
    val categoryId: String? = null,
)

/** Catégorie de rayon en cache. `id` est l'identifiant stable de `categories.json`, référencé par `categoryId`. */
@Entity(tableName = "categories")
data class CategoryEntity(
    @PrimaryKey val id: String,
    val slug: String,
    val rank: Int,
    val label: String,
    /** Identifiant serveur (`smallint`), apparié par slug. `null` tant que le serveur ne connaît pas ce slug. */
    val remoteId: Int? = null,
)

/** Version de `categories.json` déjà appliquée, écrite dans la même transaction que les catégories. */
@Entity(tableName = "category_seed_state")
data class CategorySeedStateEntity(
    @PrimaryKey val id: String = SINGLETON_ID,
    val version: Int,
) {
    companion object {
        /** Ligne unique. */
        const val SINGLETON_ID = "categories"
    }
}

/** Entrée de la file d'envoi, locale (#9 §5). */
@Entity(
    tableName = "outbox",
    indices = [Index("nextAttemptAt"), Index("sequence", unique = true), Index("entityId")],
)
data class OutboxEntryEntity(
    @PrimaryKey val id: String,
    /** Ordre de traitement, alloué par `OutboxDao.enqueue` : `createdAt` ne le garantit pas. */
    val sequence: Long,
    /** Stocké en texte (`OutboxKind.raw`) pour qu'un type inconnu ne fasse pas échouer la lecture. */
    val kindRaw: String,
    val entityId: String,
    /** Charge utile JSON, locale à l'appareil. */
    val payload: ByteArray,
    val createdAt: Instant,
    val attempts: Int = 0,
    val nextAttemptAt: Instant,
    val lastError: String? = null,
    /** `FAILED` : erreur définitive, l'entrée n'est plus rejouée (#9 §5.3). */
    val syncState: SyncState = SyncState.PENDING,
    /** Première erreur serveur d'une suite ininterrompue. */
    val serverFailingSince: Instant? = null,
) {
    /** `null` si le type stocké est inconnu de cette version de l'app. */
    fun kind(): OutboxKind? = OutboxKind.fromRaw(kindRaw)

    override fun equals(other: Any?): Boolean =
        this === other ||
            (
                other is OutboxEntryEntity &&
                    id == other.id &&
                    sequence == other.sequence &&
                    kindRaw == other.kindRaw &&
                    entityId == other.entityId &&
                    payload.contentEquals(other.payload) &&
                    createdAt == other.createdAt &&
                    attempts == other.attempts &&
                    nextAttemptAt == other.nextAttemptAt &&
                    lastError == other.lastError &&
                    syncState == other.syncState &&
                    serverFailingSince == other.serverFailingSince
            )

    override fun hashCode(): Int = 31 * id.hashCode() + payload.contentHashCode()
}
