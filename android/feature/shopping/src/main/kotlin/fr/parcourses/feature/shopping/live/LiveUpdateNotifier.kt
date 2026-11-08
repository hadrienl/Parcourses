package fr.parcourses.feature.shopping.live

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import kotlin.time.Duration

/** Accès aux notifications du système, isolé pour tester le contrôleur sans lui. */
interface LiveUpdateNotifier {
    /** Autorisation accordée et notifications de l'app actives. */
    fun canPost(): Boolean

    /** Affiche ou remplace la notification (une seule pour toute l'app). Renvoie `false` si le système refuse. */
    fun post(
        state: ShoppingLiveState,
        timeout: Duration,
    ): Boolean

    fun cancel()

    /** Notification affichée, lue dans le système : elle survit à la mort du processus. */
    fun active(): Active

    sealed interface Active {
        data object None : Active

        /** Affichée, mais illisible (autre version de l'app) : à retirer. */
        data object Unreadable : Active

        data class Shown(
            val state: ShoppingLiveState,
        ) : Active
    }
}

/** Journal de la Live Update : un échec est toujours tracé, jamais avalé. */
interface LiveUpdateLog {
    fun info(message: String)

    fun warn(
        message: String,
        error: Throwable? = null,
    )

    fun error(
        message: String,
        error: Throwable? = null,
    )
}

object AndroidLiveUpdateLog : LiveUpdateLog {
    private const val TAG = "LiveUpdate"

    override fun info(message: String) {
        Log.i(TAG, message)
    }

    override fun warn(
        message: String,
        error: Throwable?,
    ) {
        Log.w(TAG, message, error)
    }

    override fun error(
        message: String,
        error: Throwable?,
    ) {
        Log.e(TAG, message, error)
    }
}

/** Ce que la Live Update retient entre deux lancements. */
interface LiveUpdatePreferences {
    /** Visite dont la personne a écarté la notification : elle ne revient pas pour cette visite. */
    var dismissedVisitId: String?

    /** L'explication de l'autorisation a déjà été montrée : on ne la redemande pas. */
    var permissionAsked: Boolean
}

class SharedPreferencesLiveUpdatePreferences(
    context: Context,
) : LiveUpdatePreferences {
    private val prefs = context.getSharedPreferences("live_updates", Context.MODE_PRIVATE)

    override var dismissedVisitId: String?
        get() = prefs.getString(KEY_DISMISSED, null)
        // Écrit tout de suite : le processus a pu démarrer pour ce seul geste et s'arrêter juste après.
        set(value) = prefs.edit(commit = true) { putString(KEY_DISMISSED, value) }

    override var permissionAsked: Boolean
        get() = prefs.getBoolean(KEY_ASKED, false)
        set(value) = prefs.edit { putBoolean(KEY_ASKED, value) }

    private companion object {
        const val KEY_DISMISSED = "dismissed_visit_id"
        const val KEY_ASKED = "permission_asked"
    }
}

/** Notifications du système. Le canal est créé à la première publication. */
class SystemLiveUpdateNotifier(
    context: Context,
) : LiveUpdateNotifier {
    private val context = context.applicationContext
    private val compat = NotificationManagerCompat.from(this.context)
    private var hasChannel = false

    override fun canPost(): Boolean = hasPermission() && compat.areNotificationsEnabled()

    override fun post(
        state: ShoppingLiveState,
        timeout: Duration,
    ): Boolean {
        // Vérifiée ici même : l'autorisation peut être retirée à tout moment dans les réglages.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        if (!hasChannel) {
            LiveUpdateNotifications.ensureChannel(context)
            hasChannel = true
        }
        return try {
            compat.notify(
                LiveUpdateNotifications.NOTIFICATION_ID,
                LiveUpdateNotifications.build(context, state, timeout),
            )
            true
        } catch (e: SecurityException) {
            AndroidLiveUpdateLog.error("Notification refusée par le système", e)
            false
        }
    }

    override fun cancel() {
        compat.cancel(LiveUpdateNotifications.NOTIFICATION_ID)
    }

    override fun active(): LiveUpdateNotifier.Active {
        val shown =
            context
                .getSystemService(NotificationManager::class.java)
                ?.activeNotifications
                ?.firstOrNull { it.id == LiveUpdateNotifications.NOTIFICATION_ID }
        val state =
            shown?.let {
                ShoppingLiveState.decode(it.notification.extras.getString(LiveUpdateNotifications.EXTRA_STATE))
            }
        return when {
            shown == null -> LiveUpdateNotifier.Active.None
            state == null -> LiveUpdateNotifier.Active.Unreadable
            else -> LiveUpdateNotifier.Active.Shown(state)
        }
    }

    private fun hasPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
}
