package fr.parcourses.feature.storepicker

import android.content.Context
import androidx.core.content.edit

/**
 * Ce que l'app retient de la demande de localisation d'une ouverture de l'écran à l'autre (#54). Rien sur la
 * position elle-même : seulement le fait que la personne a refusé avec « Ne plus demander ».
 */
interface LocationPermissionMemory {
    /** Refus définitif : seule la page des réglages de l'app peut rendre l'accès. */
    var deniedPermanently: Boolean
}

/** En mémoire : pour les tests, et pour une app sans stockage. */
class InMemoryLocationPermissionMemory(
    override var deniedPermanently: Boolean = false,
) : LocationPermissionMemory

/** Préférences de l'app : survit à la mort du processus. */
class SharedPreferencesLocationPermissionMemory(
    context: Context,
) : LocationPermissionMemory {
    private val prefs = context.getSharedPreferences("location_permission", Context.MODE_PRIVATE)

    override var deniedPermanently: Boolean
        get() = prefs.getBoolean(KEY_DENIED_PERMANENTLY, false)
        set(value) = prefs.edit { putBoolean(KEY_DENIED_PERMANENTLY, value) }

    private companion object {
        const val KEY_DENIED_PERMANENTLY = "denied_permanently"
    }
}
