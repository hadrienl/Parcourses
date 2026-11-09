package fr.parcourses.core.designsystem

import android.app.UiModeManager
import android.content.Context
import android.database.ContentObserver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.IntOffset
import androidx.core.content.ContextCompat

/**
 * Préférences d'accessibilité lues sur le système et transmises par [ParcoursesTheme].
 *
 * [reducedMotion] : « Supprimer les animations » (échelle de durée des animations à 0). Compose ramène alors déjà
 * toutes ses animations à zéro, fondus compris : il n'y a pas de fondu de remplacement possible sur Android (iOS garde
 * des fondus de 150 ms). Les écrans s'en servent pour ne déclarer aucun déplacement (réordonnancement instantané).
 *
 * [highContrast] : niveau de contraste du système au-dessus du standard (Android 14+, réglage « Contraste ») : fil plus
 * épais, fil inactif et perles vides renforcés (iOS : « Augmenter le contraste »).
 */
data class AccessibilityPreferences(
    val reducedMotion: Boolean = false,
    val highContrast: Boolean = false,
)

val LocalAccessibilityPreferences = staticCompositionLocalOf { AccessibilityPreferences() }

/** Mouvements du ticket (`shared.motion`), ou leur absence en mouvement réduit. */
object TicketMotion {
    /** Durée de la coche (`motion.check`). */
    const val CHECK_MS = 250

    /** Glissement des lignes au réordonnancement : ressort sans dépassement (`motion.reorder`, 400 ms). */
    fun reorder(reduced: Boolean): FiniteAnimationSpec<IntOffset>? =
        if (reduced) null else spring(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = Spring.StiffnessMediumLow)

    /** Fondu d'apparition ou de disparition d'une ligne ; aucun en mouvement réduit. */
    fun <T> fade(reduced: Boolean): FiniteAnimationSpec<T>? = if (reduced) null else tween(FADE_MS)

    /** Changement d'état de la perle et du fil à la coche. */
    fun <T> check(reduced: Boolean): FiniteAnimationSpec<T> = tween(if (reduced) 0 else CHECK_MS)

    private const val FADE_MS = 150
}

/** Suit l'échelle de durée des animations du système (« Supprimer les animations »). */
@Composable
fun rememberReducedMotion(): Boolean {
    val context = LocalContext.current
    var reduced by remember(context) { mutableStateOf(isReducedMotion(context)) }
    DisposableEffect(context) {
        val observer =
            object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    reduced = isReducedMotion(context)
                }
            }
        val uri = Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE)
        context.contentResolver.registerContentObserver(uri, false, observer)
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    return reduced
}

private fun isReducedMotion(context: Context): Boolean =
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

/** Suit le niveau de contraste du système (Android 14+) ; toujours `false` avant. */
@Composable
fun rememberHighContrast(): Boolean {
    val context = LocalContext.current
    val manager =
        remember(context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                context.getSystemService(UiModeManager::class.java)
            } else {
                null
            }
        }
    var high by remember(manager) { mutableStateOf(manager != null && isHighContrast(manager)) }
    DisposableEffect(manager) {
        if (manager == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            onDispose { }
        } else {
            val listener = UiModeManager.ContrastChangeListener { contrast -> high = contrast > 0f }
            manager.addContrastChangeListener(ContextCompat.getMainExecutor(context), listener)
            onDispose { manager.removeContrastChangeListener(listener) }
        }
    }
    return high
}

private fun isHighContrast(manager: UiModeManager): Boolean =
    Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && manager.contrast > 0f
