package fr.parcourses.feature.shopping.live

import android.Manifest
import android.app.Application
import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.time.Duration.Companion.minutes

/** Construction de la notification et accès au système (`ShadowNotificationManager`). */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [36])
class LiveUpdateNotificationsTest {
    private val context: Context = ApplicationProvider.getApplicationContext()
    private val manager = context.getSystemService(NotificationManager::class.java)

    private val state =
        liveState(
            checked = listOf(liveItem("a", "produce", 0)),
            pending = listOf(liveItem("b", "bakery", 1), liveItem("c", "dairy", 2)),
        )

    private fun build(s: ShoppingLiveState = state) = LiveUpdateNotifications.build(context, s, 30.minutes)

    @Test
    fun theNextItemIsTheTitleWithItsAisleAndWhatRemains() {
        val n = build()

        assertEquals("Article b", n.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals(
            "Rayon bakery · 2 articles restants sur 3",
            n.extras.getCharSequence(Notification.EXTRA_TEXT).toString(),
        )
        assertEquals("Carrefour", n.extras.getCharSequence(Notification.EXTRA_SUB_TEXT).toString())
        assertEquals("2", n.extras.getString("android.shortCriticalText"))
    }

    @Test
    fun itAsksToBePromotedAndMeetsTheLiveUpdateRequirements() {
        val n = build()

        assertTrue(n.extras.getBoolean(Notification.EXTRA_REQUEST_PROMOTED_ONGOING))
        assertTrue(n.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(n.flags and Notification.FLAG_ONLY_ALERT_ONCE != 0)
        // Une Live Update ne doit pas être colorée (`setColorized`) ni être le résumé d'un groupe.
        assertFalse(n.extras.getBoolean(Notification.EXTRA_COLORIZED))
        assertTrue(n.flags and Notification.FLAG_GROUP_SUMMARY == 0)
        assertEquals(LiveUpdateNotifications.CHANNEL_ID, n.channelId)
        assertEquals(30.minutes.inWholeMilliseconds, n.timeoutAfter)
        assertNotNull(n.contentIntent)
        assertNotNull(n.deleteIntent)
    }

    @Test
    fun onAndroid16TheBarHasOneSegmentPerAisleAndOnePointPerItem() {
        val style = Notification.Builder.recoverBuilder(context, build()).style as Notification.ProgressStyle

        assertEquals(listOf(2, 2, 2), style.progressSegments.map { it.length })
        assertEquals(listOf(1, 3, 5), style.progressPoints.map { it.position })
        assertEquals(LIVE_PALETTE[1], style.progressSegments[1].color)
        assertEquals(2, style.progress)
        assertEquals(6, style.progressMax)
        assertTrue(style.isStyledByProgress)
    }

    @Test
    @Config(sdk = [35])
    fun beforeAndroid16ItFallsBackToASimpleBar() {
        val n = build()

        assertEquals(6, n.extras.getInt(Notification.EXTRA_PROGRESS_MAX))
        assertEquals(2, n.extras.getInt(Notification.EXTRA_PROGRESS))
        assertEquals("Article b", n.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertTrue(n.flags and Notification.FLAG_ONGOING_EVENT != 0)
    }

    @Test
    fun theNextItemIsPrivateAndThePublicVersionOnlyCountsWhatRemains() {
        val n = build()

        assertEquals(Notification.VISIBILITY_PRIVATE, n.visibility)
        val public = n.publicVersion
        assertNotNull(public)
        assertEquals("Courses en cours", public.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertEquals("2 articles restants sur 3", public.extras.getCharSequence(Notification.EXTRA_TEXT).toString())
        assertTrue(public.actions.isNullOrEmpty())
        val texts = public.extras.keySet().mapNotNull { public.extras.getCharSequence(it)?.toString() }
        assertFalse(texts.any { "Article" in it || "Rayon" in it })
    }

    @Test
    fun theCheckNextActionTargetsTheDisplayedNextItem() {
        val n = build()

        assertEquals(1, n.actions.size)
        assertEquals("Cocher le suivant", n.actions[0].title.toString())
        val intent = shadowOf(n.actions[0].actionIntent).savedIntent
        assertEquals(LiveUpdateReceiver.ACTION_CHECK_NEXT, intent.action)
        assertEquals("v1", intent.getStringExtra(LiveUpdateReceiver.EXTRA_VISIT_ID))
        assertEquals("b", intent.getStringExtra(LiveUpdateReceiver.EXTRA_ITEM_ID))
    }

    @Test
    fun anUpdateNeverRewritesTheActionOfTheNotificationAlreadyShown() {
        val first = build()
        // Après une coche, la notification suivante propose `c` : l'action de la première doit toujours cocher `b`.
        val second = build(state.copy(pending = state.pending.drop(1), checked = state.checked + state.pending.take(1)))

        assertEquals(
            "b",
            shadowOf(first.actions[0].actionIntent).savedIntent.getStringExtra(LiveUpdateReceiver.EXTRA_ITEM_ID),
        )
        assertEquals(
            "c",
            shadowOf(second.actions[0].actionIntent).savedIntent.getStringExtra(LiveUpdateReceiver.EXTRA_ITEM_ID),
        )
    }

    @Test
    fun manyAislesStayWithinTheTenSegmentsAndroidDraws() {
        val many = liveState(pending = (0 until 12).map { liveItem("i$it", "aisle$it", it) })
        val style = Notification.Builder.recoverBuilder(context, build(many)).style as Notification.ProgressStyle

        assertEquals(10, style.progressSegments.size)
        assertEquals(24, style.progressMax)
        // Plus de 4 articles : le système n'en dessinerait que 4, aucun point.
        assertTrue(style.progressPoints.isEmpty())
    }

    @Test
    fun theNotificationOpensItsVisitInTheApp() {
        val intent = shadowOf(build().contentIntent).savedIntent

        assertEquals("parcourses://shopping/v1", intent.dataString)
        assertEquals(context.packageName, intent.`package`)
    }

    @Test
    fun withEverythingTakenThereIsNoAction() {
        val n = build(liveState(pending = emptyList(), checked = listOf(liveItem("a"))))

        assertEquals("Tout est pris", n.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
        assertTrue(n.actions.isNullOrEmpty())
        // Singulier à zéro, comme iOS.
        val public =
            n.publicVersion.extras
                .getCharSequence(Notification.EXTRA_TEXT)
                .toString()
        assertEquals("0 article restant sur 1", public)
    }

    @Test
    fun aSingleRemainingItemIsSingular() {
        val n = build(liveState(pending = listOf(liveItem("a")), checked = listOf(liveItem("b"))))

        assertEquals(
            "Rayon dairy · 1 article restant sur 2",
            n.extras.getCharSequence(Notification.EXTRA_TEXT).toString(),
        )
    }

    // region Système

    @Test
    fun theSystemNotifierPostsReadsBackAndCancelsTheSingleNotification() {
        shadowOf(context as Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = SystemLiveUpdateNotifier(context)

        assertTrue(notifier.canPost())
        assertTrue(notifier.post(state, 10.minutes))
        assertTrue(notifier.post(state.copy(pending = state.pending.drop(1)), 10.minutes))

        assertEquals(1, shadowOf(manager).allNotifications.size)
        assertNotNull(manager.getNotificationChannel(LiveUpdateNotifications.CHANNEL_ID))
        assertEquals(LiveUpdateNotifier.Active.Shown(state.copy(pending = state.pending.drop(1))), notifier.active())
        notifier.cancel()
        assertEquals(LiveUpdateNotifier.Active.None, notifier.active())
    }

    @Test
    fun withoutPermissionNothingIsPosted() {
        shadowOf(context as Application).denyPermissions(Manifest.permission.POST_NOTIFICATIONS)
        val notifier = SystemLiveUpdateNotifier(context)

        assertFalse(notifier.canPost())
        assertFalse(notifier.post(state, 10.minutes))
        assertTrue(shadowOf(manager).allNotifications.isEmpty())
    }

    @Test
    fun aNotificationFromAnotherVersionIsUnreadable() {
        shadowOf(context as Application).grantPermissions(Manifest.permission.POST_NOTIFICATIONS)
        LiveUpdateNotifications.ensureChannel(context)
        manager.notify(
            LiveUpdateNotifications.NOTIFICATION_ID,
            Notification
                .Builder(context, LiveUpdateNotifications.CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .build(),
        )

        assertEquals(LiveUpdateNotifier.Active.Unreadable, SystemLiveUpdateNotifier(context).active())
        assertNull((SystemLiveUpdateNotifier(context).active() as? LiveUpdateNotifier.Active.Shown)?.state)
    }

    // endregion
}
