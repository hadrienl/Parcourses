package fr.parcourses.core.network

import kotlinx.coroutines.flow.Flow
import kotlin.uuid.Uuid

/** Ce qui arrive sur le canal privé `user:<uid>` (#87 §6.2). */
sealed interface RealtimeEvent {
    /** Canal (re)joint : les messages manqués ne sont pas rejoués, une descente s'impose. */
    data object Subscribed : RealtimeEvent

    /** Signal `changed` : `{ list_id, kind }`, sans aucun libellé. [listId] nul pour une invitation reçue. */
    data class Changed(
        val listId: Uuid?,
        val kind: String,
    ) : RealtimeEvent
}

/** Canal temps réel d'un compte. [SupabaseGateway] l'implémente avec le Realtime de supabase-kt. */
fun interface RealtimeSignalSource {
    /**
     * Ouvre le canal privé `user:<userId>` à la collecte et le ferme à l'annulation (le WebSocket se ferme quand plus
     * aucun canal n'est ouvert). Le jeton d'accès suit la session (rafraîchissements compris).
     */
    fun signals(userId: Uuid): Flow<RealtimeEvent>
}
