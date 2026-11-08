package fr.parcourses.feature.shopping.live

import fr.parcourses.feature.shopping.ShoppingRow
import kotlin.time.Duration

/** Notifications simulées : ce qui serait affiché, et chaque affichage. */
class FakeNotifier : LiveUpdateNotifier {
    var allowed = true
    var shown: LiveUpdateNotifier.Active = LiveUpdateNotifier.Active.None
    val posts = mutableListOf<Pair<ShoppingLiveState, Duration>>()
    var cancels = 0

    val state: ShoppingLiveState? get() = (shown as? LiveUpdateNotifier.Active.Shown)?.state

    override fun canPost() = allowed

    override fun post(
        state: ShoppingLiveState,
        timeout: Duration,
    ): Boolean {
        if (!allowed) return false
        posts += state to timeout
        shown = LiveUpdateNotifier.Active.Shown(state)
        return true
    }

    override fun cancel() {
        if (shown != LiveUpdateNotifier.Active.None) cancels++
        shown = LiveUpdateNotifier.Active.None
    }

    override fun active() = shown
}

class FakePreferences : LiveUpdatePreferences {
    override var dismissedVisitId: String? = null
    override var permissionAsked: Boolean = false
}

class RecordingLog : LiveUpdateLog {
    val entries = mutableListOf<String>()

    override fun info(message: String) {
        entries += "I $message"
    }

    override fun warn(
        message: String,
        error: Throwable?,
    ) {
        entries += "W $message"
    }

    override fun error(
        message: String,
        error: Throwable?,
    ) {
        entries += "E $message ${error?.message}"
    }
}

/** Ce que le mode courses envoie à la Live Update. */
class RecordingSink : LiveUpdateSink {
    val published = mutableListOf<ShoppingLiveState>()
    val ended = mutableListOf<String>()

    override fun publish(state: ShoppingLiveState) {
        published += state
    }

    override fun end(visitId: String) {
        ended += visitId
    }
}

fun liveItem(
    id: String,
    aisle: String = "dairy",
    index: Int = 0,
) = LiveItem(id = id, label = "Article $id", aisleId = aisle, aisleLabel = "Rayon $aisle", aisleIndex = index)

fun liveState(
    pending: List<LiveItem>,
    checked: List<LiveItem> = emptyList(),
    visitId: String = "v1",
) = ShoppingLiveState(visitId, "l1", "Courses", "Carrefour", pending, checked)

fun row(
    id: String,
    checked: Boolean = false,
    aisle: String = "dairy",
) = ShoppingRow(id, "Article $id", null, checked, aisle)
