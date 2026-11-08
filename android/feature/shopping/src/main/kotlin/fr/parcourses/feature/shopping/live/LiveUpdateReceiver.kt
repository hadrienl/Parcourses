package fr.parcourses.feature.shopping.live

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.time.Duration.Companion.seconds

/**
 * Actions de la Live Update : « Cocher le suivant » (écriture Room, puis réveil de la synchronisation par le
 * repository) et notification écartée. L'app n'a pas besoin d'être au premier plan, ni même lancée : le processus
 * démarre pour l'occasion et retrouve l'ordre affiché dans la notification.
 */
class LiveUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val host = context.applicationContext as? LiveUpdateHost
        val visitId = intent.getStringExtra(EXTRA_VISIT_ID)
        if (host == null || visitId == null) {
            AndroidLiveUpdateLog.error("Action de Live Update illisible : ${intent.action}")
            return
        }
        when (intent.action) {
            ACTION_CHECK_NEXT -> {
                val itemId =
                    intent.getStringExtra(EXTRA_ITEM_ID) ?: run {
                        AndroidLiveUpdateLog.error("« Cocher le suivant » sans article")
                        return
                    }
                // `goAsync` garde le processus en vie le temps de l'écriture et de la nouvelle notification. `null`
                // seulement quand le receiver est appelé à la main (tests).
                val pending: PendingResult? = goAsync()
                val done = host.liveUpdates.checkNext(visitId, itemId)
                scope.launch {
                    if (withTimeoutOrNull(BUDGET) { done.await() } == null) {
                        AndroidLiveUpdateLog.warn("« Cocher le suivant » plus long que prévu")
                    }
                    pending?.finish()
                }
            }

            ACTION_DISMISSED -> {
                host.liveUpdates.dismissed(visitId)
            }

            else -> {
                AndroidLiveUpdateLog.error("Action de Live Update inconnue : ${intent.action}")
            }
        }
    }

    companion object {
        const val ACTION_CHECK_NEXT = "fr.parcourses.live.CHECK_NEXT"
        const val ACTION_DISMISSED = "fr.parcourses.live.DISMISSED"
        const val EXTRA_VISIT_ID = "visitId"
        const val EXTRA_ITEM_ID = "itemId"

        /** Un receiver dispose d'environ 10 s après `goAsync`. */
        private val BUDGET = 8.seconds
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    }
}
