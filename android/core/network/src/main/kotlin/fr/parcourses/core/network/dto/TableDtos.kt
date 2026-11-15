@file:UseSerializers(UuidSerializer::class, InstantSerializer::class)

package fr.parcourses.core.network.dto

import fr.parcourses.core.network.RemoteJson
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.descriptors.elementNames
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
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

/** `updated_by` : dernier compte qui a modifié la liste, posé par le serveur (#87, nul après sa suppression). */
@Serializable
data class ListRow(
    val id: Uuid,
    @SerialName("owner_id") val ownerId: Uuid,
    val name: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("updated_at") val updatedAt: Instant,
    @SerialName("updated_by") val updatedBy: Uuid? = null,
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
    /** Dernier compte qui a modifié l'article (#87), posé par le serveur. */
    @SerialName("updated_by") val updatedBy: Uuid? = null,
) {
    companion object {
        internal val spec = TableSpec("list_items", serializer())
    }
}

/** Pierre tombale d'un article supprimé (#87, lot 87.1), gardée 30 jours par le serveur. */
@Serializable
data class TombstoneRow(
    val id: Uuid,
    @SerialName("list_id") val listId: Uuid,
    @SerialName("deleted_at") val deletedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("list_item_tombstones", serializer())
    }
}

/** Prénom affiché aux membres des listes partagées (#87). Une ligne par compte e-mail. */
@Serializable
data class ProfileRow(
    @SerialName("user_id") val userId: Uuid,
    @SerialName("display_name") val displayName: String,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("updated_at") val updatedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("profiles", serializer())
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

/**
 * Champs d'un article à mettre à jour (#87 §6.4, même nom qu'iOS) : [columns] sont des noms de colonnes serveur, leurs
 * valeurs viennent de [values]. Seuls ces champs partent : la coche d'un autre appareil n'est pas écrasée par un
 * changement de quantité.
 */
class ListItemFields(
    val values: ListItemUpsert,
    val columns: List<String>,
) {
    init {
        require(columns.isNotEmpty()) { "aucun champ" }
        require(columns.all { it in ALL }) { "champ non modifiable" }
    }

    /** Corps du `PATCH` : uniquement [columns], `null` explicites compris. */
    internal fun toJson(): JsonObject {
        val all = RemoteJson.encodeToJsonElement(ListItemUpsert.serializer(), values).jsonObject
        return JsonObject(columns.associateWith { all.getValue(it) })
    }

    override fun equals(other: Any?): Boolean =
        other is ListItemFields && columns == other.columns && values == other.values

    override fun hashCode(): Int = 31 * columns.hashCode() + values.hashCode()

    override fun toString(): String = "ListItemFields($columns)"

    companion object {
        const val CHECKED_AT = "checked_at"
        const val LABEL = "label"
        const val LIST_ID = "list_id"
        const val PRODUCT_ID = "product_id"
        const val QUANTITY = "quantity"

        /**
         * Colonnes accordées en mise à jour à `authenticated` (contrôlé par le test de contrat), triées : celles d'un
         * article créé et d'une entrée d'avant la version 2 de la base.
         */
        val ALL: List<String> = listOf(CHECKED_AT, LABEL, LIST_ID, PRODUCT_ID, QUANTITY)
    }
}

@Serializable
internal data class ProfilePatch(
    @SerialName("display_name") val displayName: String,
)

@Serializable
internal data class VisitClose(
    @SerialName("ended_at") val endedAt: Instant,
)

// endregion
