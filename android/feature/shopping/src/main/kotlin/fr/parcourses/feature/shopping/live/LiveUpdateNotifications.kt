package fr.parcourses.feature.shopping.live

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.core.app.NotificationCompat
import androidx.core.net.toUri
import fr.parcourses.feature.shopping.R
import kotlin.time.Duration

/**
 * Notification de la Live Update (#10 §9) : `ProgressStyle` (barre segmentée par rayon, un point par article), promue
 * en Live Update sur Android 16 et plus, simple notification en cours en dessous. `NotificationCompat.ProgressStyle`
 * se replie seul en barre simple (`setProgress`) avant Android 16.
 *
 * Confidentialité : le prochain article est privé (`VISIBILITY_PRIVATE`) ; l'écran verrouillé qui masque les
 * contenus sensibles montre la version publique, « N articles restants », comme `.privacySensitive()` sur iOS.
 */
object LiveUpdateNotifications {
    const val CHANNEL_ID = "shopping_live"
    const val NOTIFICATION_ID = 10_010

    /** État complet de la notification : relu après la mort du processus (voir [ShoppingLiveState]). */
    const val EXTRA_STATE = "fr.parcourses.live.STATE"

    private const val REQUEST_OPEN = 1
    private const val REQUEST_CHECK_NEXT = 2
    private const val REQUEST_DISMISSED = 3

    /** Canal silencieux mais visible sur l'écran verrouillé : la Live Update n'alerte jamais. */
    fun ensureChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.live_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.live_channel_description)
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            }
        manager.createNotificationChannel(channel)
    }

    /** Notification complète de [state]. [timeout] : temps restant avant que la visite soit périmée (45 min). */
    fun build(
        context: Context,
        state: ShoppingLiveState,
        timeout: Duration,
    ): Notification {
        val next = state.next
        val remaining = remainingText(context, state)
        val text = listOfNotNull(next?.aisleLabel, remaining).joinToString(" · ")
        val builder =
            base(context, state)
                .setContentTitle(next?.label ?: context.getString(R.string.live_all_taken))
                .setContentText(if (next == null) context.getString(R.string.live_finish_in_app) else text)
                .setSubText(state.storeName ?: state.listName)
                .setStyle(progressStyle(state))
                .setTimeoutAfter(timeout.inWholeMilliseconds.coerceAtLeast(1))
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(publicVersion(context, state))
                .setDeleteIntent(broadcast(context, LiveUpdateReceiver.ACTION_DISMISSED, state.visitId, null))
                .addExtras(Bundle().apply { putString(EXTRA_STATE, state.encode()) })
        if (next != null) {
            builder.addAction(
                NotificationCompat.Action
                    .Builder(
                        R.drawable.ic_stat_shopping,
                        context.getString(R.string.live_check_next),
                        broadcast(context, LiveUpdateReceiver.ACTION_CHECK_NEXT, state.visitId, next.id),
                    ).build(),
            )
        }
        return builder.build()
    }

    /** Ce que montre un écran verrouillé qui masque les contenus sensibles : ni article ni rayon. */
    private fun publicVersion(
        context: Context,
        state: ShoppingLiveState,
    ): Notification =
        base(context, state)
            .setContentTitle(context.getString(R.string.live_public_title))
            .setContentText(remainingText(context, state))
            .setProgress(state.total, state.total - state.remaining, false)
            .build()

    private fun base(
        context: Context,
        state: ShoppingLiveState,
    ): NotificationCompat.Builder =
        NotificationCompat
            .Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_shopping)
            .setColor(LIVE_PALETTE.first())
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            // Puce de la barre d'état : le nombre d'articles restants, comme la Dynamic Island sur iOS.
            .setShortCriticalText(state.remaining.toString())
            .setRequestPromotedOngoing(true)
            .setContentIntent(open(context, state.visitId))

    private fun progressStyle(state: ShoppingLiveState): NotificationCompat.ProgressStyle {
        val model = LiveProgress.of(state)
        return NotificationCompat
            .ProgressStyle()
            .setStyledByProgress(true)
            .setProgressSegments(
                model.segments.map {
                    NotificationCompat.ProgressStyle.Segment(it.length).setColor(LIVE_PALETTE[it.colorIndex])
                },
            ).setProgressPoints(
                model.points.map {
                    NotificationCompat.ProgressStyle.Point(it.position).setColor(LIVE_PALETTE[it.colorIndex])
                },
            ).setProgress(model.progress)
    }

    private fun remainingText(
        context: Context,
        state: ShoppingLiveState,
    ): String =
        context.resources.getQuantityString(R.plurals.live_remaining, state.remaining, state.remaining, state.total)

    /** Rouvre le mode courses de cette visite (lien profond, pile `[Lists, Shopping]`). */
    private fun open(
        context: Context,
        visitId: String,
    ): PendingIntent {
        val intent =
            Intent(Intent.ACTION_VIEW, LiveUpdateLinks.shopping(visitId).toUri())
                .setPackage(context.packageName)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            context,
            REQUEST_OPEN,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun broadcast(
        context: Context,
        action: String,
        visitId: String,
        itemId: String?,
    ): PendingIntent {
        val intent =
            Intent(context, LiveUpdateReceiver::class.java)
                .setAction(action)
                .putExtra(LiveUpdateReceiver.EXTRA_VISIT_ID, visitId)
                .putExtra(LiveUpdateReceiver.EXTRA_ITEM_ID, itemId)
        val request = if (action == LiveUpdateReceiver.ACTION_CHECK_NEXT) REQUEST_CHECK_NEXT else REQUEST_DISMISSED
        return PendingIntent.getBroadcast(
            context,
            request,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }
}
