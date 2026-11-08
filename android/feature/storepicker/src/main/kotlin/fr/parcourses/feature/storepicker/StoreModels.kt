package fr.parcourses.feature.storepicker

import androidx.compose.runtime.Immutable
import fr.parcourses.core.location.FixSelection
import fr.parcourses.core.location.LocationFix
import fr.parcourses.core.network.dto.NearbyStoreRow
import fr.parcourses.core.network.dto.StoreSearchRow
import java.util.Locale

/** Magasin affichable, indépendant de Room et du réseau. */
@Immutable
data class StoreCandidate(
    val id: String,
    val name: String,
    val chain: String? = null,
    val address: String? = null,
    /** `null` quand elle n'a pas de sens : position approximative, recherche, magasin récent. */
    val distanceM: Double? = null,
    /** Rayon bio tel que le serveur vient de le dire. `null` pour un récent : le choisir ne doit rien réécrire. */
    val organicAisle: Boolean? = null,
)

internal fun NearbyStoreRow.toCandidate(keepsDistance: Boolean) =
    StoreCandidate(
        id = id.toString(),
        name = name,
        chain = chain,
        address = address,
        distanceM = if (keepsDistance) distanceM else null,
        organicAisle = organicAisle,
    )

internal fun StoreSearchRow.toCandidate() =
    StoreCandidate(id = id.toString(), name = name, chain = chain, address = address, organicAisle = organicAisle)

/**
 * Résultat de l'écran, consommé par le mode courses (A8). [WithoutStore] : ordre générique, et aucune visite
 * créée (#10 §8).
 */
sealed interface StorePickerOutcome {
    /** [id] est celui du magasin, déjà en cache local. */
    data class Store(
        val id: String,
    ) : StorePickerOutcome

    data object WithoutStore : StorePickerOutcome
}

/** Règles de présentation des magasins proches. Mêmes constantes qu'iOS (9.8). */
object StoreRanking {
    const val PRECISE_RADIUS_M = 3_000
    const val APPROXIMATE_RADIUS_M = 10_000
    const val MAX_RESULTS = 10
    const val RECENT_LIMIT = 5
    const val SEARCH_LIMIT = 20

    /** Au-delà, le magasin n'est pas proposé d'office. */
    const val PROPOSAL_MAX_DISTANCE_M = 150.0

    /** Écart minimal avec le deuxième magasin pour être « nettement plus proche », relevé par l'imprécision. */
    const val PROPOSAL_MIN_GAP_M = 50.0

    /** Magasin à proposer en tête : l'écart doit dépasser ce que l'imprécision du point peut expliquer. */
    fun proposal(
        stores: List<StoreCandidate>,
        fix: LocationFix,
    ): StoreCandidate? {
        val usable = !fix.isStale && fix.horizontalAccuracyM <= FixSelection.TARGET_ACCURACY_M
        val ranked = if (usable) stores.filter { it.distanceM != null }.sortedBy { it.distanceM } else emptyList()
        val first = ranked.firstOrNull()
        val distance = first?.distanceM
        val next = ranked.getOrNull(1)?.distanceM
        return when {
            first == null || distance == null || distance >= PROPOSAL_MAX_DISTANCE_M -> null
            next == null -> first
            next - distance >= maxOf(PROPOSAL_MIN_GAP_M, fix.horizontalAccuracyM) -> first
            else -> null
        }
    }
}

/** Distance lisible et arrondie : le GPS ne justifie pas le mètre près. */
object StoreDistance {
    fun text(
        metres: Double,
        locale: Locale = Locale.FRANCE,
    ): String {
        // Arrondi d'abord : 996 m ne doit pas s'écrire « 1000 m ».
        val rounded = Math.round(metres / ROUND_M).toInt() * ROUND_M
        if (rounded < KM_M) return "$rounded m"
        val km = Math.round(metres / HUNDRED_M) / TEN
        return String.format(locale, "%.1f km", km)
    }

    private const val ROUND_M = 10
    private const val HUNDRED_M = 100.0
    private const val KM_M = 1000
    private const val TEN = 10.0
}
