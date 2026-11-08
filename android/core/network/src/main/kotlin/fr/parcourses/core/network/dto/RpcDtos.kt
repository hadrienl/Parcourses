@file:UseSerializers(UuidSerializer::class, InstantSerializer::class)

package fr.parcourses.core.network.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import kotlin.uuid.Uuid

/** Ligne de la RPC `nearby_stores`, hors contrat `tables.json` (ce n'est pas une table). */
@Serializable
data class NearbyStoreRow(
    val id: Uuid,
    val name: String,
    val chain: String? = null,
    val address: String? = null,
    @SerialName("distance_m") val distanceM: Double,
    /** `null` : colonne absente (serveur sans la migration #28), la valeur en cache reste. */
    @SerialName("organic_aisle") val organicAisle: Boolean? = null,
)

/** Ligne de la RPC `search_stores`. */
@Serializable
data class StoreSearchRow(
    val id: Uuid,
    val name: String,
    val chain: String? = null,
    val address: String? = null,
    /** `null` : colonne absente (serveur sans la migration #28), la valeur en cache reste. */
    @SerialName("organic_aisle") val organicAisle: Boolean? = null,
)

/** Entrée de la RPC `resolve_products` : libellé sans quantité et catégorie choisie par le classifieur. */
@Serializable
data class ProductResolutionRequest(
    val name: String,
    /** Slug partagé. `bio` ou slug inconnu du serveur : le produit n'est pas créé. */
    @SerialName("category_slug") val categorySlug: String?,
)

/**
 * Ligne de la RPC `resolve_products`, une par entrée envoyée et dans le même ordre.
 * `id` nul : le produit n'existe pas et le serveur ne l'a pas créé (catégorie refusée, quota du jour).
 */
@Serializable
data class ResolvedProductRow(
    @SerialName("normalized_name") val normalizedName: String? = null,
    val id: Uuid? = null,
    val name: String? = null,
    @SerialName("category_slug") val categorySlug: String? = null,
)

/** Réponse de la RPC `store_graph_snapshot`, sans interprétation du contenu. */
sealed interface GraphSnapshotResponse {
    /** La version connue est la version courante. */
    data object Unchanged : GraphSnapshotResponse

    /** Le magasin n'a pas encore d'instantané. */
    data object None : GraphSnapshotResponse

    /** JSON brut, à conserver tel quel (#9 §4.3). */
    data class Payload(
        val json: String,
    ) : GraphSnapshotResponse

    companion object {
        fun parse(body: String): GraphSnapshotResponse {
            if (body.isBlank()) return Unchanged
            val element = Json.parseToJsonElement(body)
            if (element is JsonNull) return Unchanged
            if (element is JsonObject &&
                element["none"]?.jsonPrimitive?.let { runCatching { it.boolean }.getOrNull() } == true
            ) {
                return None
            }
            return Payload(body)
        }
    }
}

/** Visite telle que le compte courant la voit. */
enum class VisitAccess {
    Open,
    Closed,

    /** Absente ou appartenant à un autre compte : la RLS ne permet pas de distinguer. */
    NotVisible,
}
