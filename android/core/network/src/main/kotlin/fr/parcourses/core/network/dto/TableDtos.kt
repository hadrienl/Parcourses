@file:UseSerializers(UuidSerializer::class, InstantSerializer::class)

package fr.parcourses.core.network.dto

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.descriptors.elementNames
import kotlin.time.Instant
import kotlin.uuid.Uuid

/**
 * DTO lié à une table : ses colonnes (les `@SerialName`) sont contrôlées contre
 * `shared/contract/tables.json` par le test de contrat.
 */
internal class TableSpec<T : Any>(
    val table: String,
    val serializer: KSerializer<T>,
) {
    val columns: List<String> get() = serializer.descriptor.elementNames.toList()

    /** Liste de colonnes pour `select=`. */
    val selection: String get() = columns.joinToString(",")
}

// region Lecture

@Serializable
data class ListRow(
    val id: Uuid,
    @SerialName("owner_id") val ownerId: Uuid,
    val name: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("updated_at") val updatedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("lists", serializer())
    }
}

@Serializable
data class ListItemRow(
    val id: Uuid,
    @SerialName("list_id") val listId: Uuid,
    @SerialName("product_id") val productId: Uuid?,
    val label: String,
    val quantity: String?,
    @SerialName("checked_at") val checkedAt: Instant?,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("updated_at") val updatedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("list_items", serializer())
    }
}

@Serializable
data class VisitRow(
    val id: Uuid,
    @SerialName("user_id") val userId: Uuid,
    @SerialName("store_id") val storeId: Uuid,
    @SerialName("list_id") val listId: Uuid?,
    @SerialName("list_was_sorted") val listWasSorted: Boolean,
    @SerialName("started_at") val startedAt: Instant,
    @SerialName("ended_at") val endedAt: Instant?,
    @SerialName("processed_at") val processedAt: Instant?,
) {
    companion object {
        internal val spec = TableSpec("visits", serializer())
    }
}

@Serializable
data class CheckRow(
    val id: Uuid,
    @SerialName("visit_id") val visitId: Uuid,
    @SerialName("product_id") val productId: Uuid?,
    @SerialName("category_id") val categoryId: Short?,
    @SerialName("checked_at") val checkedAt: Instant,
    val ignored: Boolean,
) {
    companion object {
        internal val spec = TableSpec("checks", serializer())
    }
}

@Serializable
data class CategoryRow(
    val id: Short,
    val slug: String,
    val name: String,
    @SerialName("default_rank") val defaultRank: Short,
) {
    companion object {
        internal val spec = TableSpec("categories", serializer())
    }
}

@Serializable
data class ProductRow(
    val id: Uuid,
    val name: String,
    @SerialName("normalized_name") val normalizedName: String,
    @SerialName("category_id") val categoryId: Short?,
    @SerialName("off_code") val offCode: String?,
    @SerialName("created_at") val createdAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("products", serializer())
    }
}

/** Produit vu par l'app : sa catégorie est le slug partagé, pas l'`Int` serveur. */
data class RemoteProduct(
    val id: Uuid,
    val name: String,
    val normalizedName: String,
    val categorySlug: String?,
    val offCode: String?,
    val createdAt: Instant,
)

// endregion

// region Écriture (limitée aux colonnes accordées à `authenticated`)

@Serializable
data class ListUpsert(
    val id: Uuid,
    val name: String,
) {
    companion object {
        internal val spec = TableSpec("lists", serializer())
    }
}

/** Les `null` sont explicites (voir `RemoteJson`) : une mise à jour doit pouvoir vider une colonne. */
@Serializable
data class ListItemUpsert(
    val id: Uuid,
    @SerialName("list_id") val listId: Uuid,
    @SerialName("product_id") val productId: Uuid?,
    val label: String,
    val quantity: String?,
    @SerialName("checked_at") val checkedAt: Instant?,
) {
    companion object {
        internal val spec = TableSpec("list_items", serializer())
    }
}

@Serializable
data class VisitInsert(
    val id: Uuid,
    @SerialName("store_id") val storeId: Uuid,
    @SerialName("list_id") val listId: Uuid?,
    @SerialName("list_was_sorted") val listWasSorted: Boolean,
    @SerialName("started_at") val startedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("visits", serializer())
    }
}

/** Une coche porte soit un produit, soit une catégorie (`checks_product_xor_category`). */
@Serializable
@ConsistentCopyVisibility
data class CheckInsert private constructor(
    val id: Uuid,
    @SerialName("visit_id") val visitId: Uuid,
    @SerialName("product_id") val productId: Uuid?,
    @SerialName("category_id") val categoryId: Short?,
    @SerialName("checked_at") val checkedAt: Instant,
) {
    companion object {
        fun forProduct(
            id: Uuid,
            visitId: Uuid,
            productId: Uuid,
            checkedAt: Instant,
        ) = CheckInsert(id, visitId, productId, null, checkedAt)

        fun forCategory(
            id: Uuid,
            visitId: Uuid,
            categoryId: Short,
            checkedAt: Instant,
        ) = CheckInsert(id, visitId, null, categoryId, checkedAt)

        internal val spec = TableSpec("checks", serializer())
    }
}

/** Coche vue par l'app : le gateway traduit le slug en `Short` serveur au moment de l'envoi. */
data class CheckUpload(
    val id: Uuid,
    val visitId: Uuid,
    val target: Target,
    val checkedAt: Instant,
) {
    sealed interface Target {
        data class Product(
            val id: Uuid,
        ) : Target

        data class Category(
            val slug: String,
        ) : Target
    }
}

// Colonnes modifiables uniquement : `id` n'a pas le privilège UPDATE, et un upsert PostgREST classique le
// réécrirait (`on conflict do update set id = …`), d'où mise à jour puis insertion.

@Serializable
internal data class ListPatch(
    val name: String,
)

@Serializable
internal data class ListItemPatch(
    @SerialName("list_id") val listId: Uuid,
    @SerialName("product_id") val productId: Uuid?,
    val label: String,
    val quantity: String?,
    @SerialName("checked_at") val checkedAt: Instant?,
)

@Serializable
internal data class VisitClose(
    @SerialName("ended_at") val endedAt: Instant,
)

// endregion
