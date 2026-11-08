package fr.parcourses.core.location

/**
 * Autorisation de localisation accordée à l'app. Android ne distingue pas « jamais demandé » de « refusé » :
 * c'est l'écran qui le sait (voir `shouldShowRequestPermissionRationale`).
 */
enum class LocationAuthorization {
    Denied,

    /** `ACCESS_COARSE_LOCATION` seule : un point à quelques kilomètres près. */
    Approximate,

    Precise,
}

/**
 * Point lu une seule fois. Il vit le temps d'une recherche : jamais enregistré ni journalisé, d'où un `toString`
 * qui ne montre rien (un journal de plantage ne doit pas situer l'utilisateur).
 */
data class LocationFix(
    val latitude: Double,
    val longitude: Double,
    /** Rayon d'incertitude en mètres ; une valeur négative veut dire « inconnu ». */
    val horizontalAccuracyM: Double,
    /** Instant de la mesure, en millisecondes depuis l'epoch. */
    val timestampMillis: Long,
    /** Point ancien : il suffit à lister des magasins, jamais à en proposer un. */
    val isStale: Boolean = false,
) {
    override fun toString(): String = "LocationFix(redacted)"
}

/** Issue d'une requête ponctuelle. */
sealed interface LocationResult {
    data class Fix(
        val fix: LocationFix,
    ) : LocationResult

    /** L'autorisation est retirée pendant la requête. */
    data object Denied : LocationResult

    /** Aucun point à l'échéance. */
    data object Unavailable : LocationResult
}

/** Accès à la position : une requête ponctuelle à la fois, au premier plan (#10 §7). */
interface LocationProvider {
    val authorization: LocationAuthorization

    /** Premier point assez précis, ou le meilleur obtenu à l'échéance. */
    suspend fun currentFix(): LocationResult
}
