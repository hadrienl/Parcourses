package fr.parcourses.feature.lists

import fr.parcourses.core.data.sharing.AcceptOutcome
import fr.parcourses.core.data.sharing.AcceptResult
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.data.sharing.SharingFailure
import fr.parcourses.core.data.sharing.SharingService
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.InvitationPreview
import fr.parcourses.core.network.dto.ListParticipant
import fr.parcourses.core.network.dto.ListSharing
import fr.parcourses.core.network.dto.PendingInvitation
import fr.parcourses.core.network.dto.ReceivedInvitation
import fr.parcourses.core.network.dto.SentInvitation
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Doublure du partage pour les modèles et les écrans : réponses programmées, appels enregistrés. */
@Suppress("TooManyFunctions")
class FakeSharingService : SharingService {
    val me: Uuid = Uuid.parse("11111111-1111-4111-8111-111111111111")
    val owner: Uuid = Uuid.parse("22222222-2222-4222-8222-222222222222")
    val listId: Uuid = Uuid.parse("33333333-3333-4333-8333-333333333333")
    val now: Instant = Instant.parse("2026-11-15T10:00:00Z")

    var sharing: ListSharing =
        ListSharing(
            listId,
            ListRole.Owner,
            ListParticipant(me, "Hadrien", isMe = true),
            members = listOf(ListParticipant(owner, "Léa", ListRole.Editor, joinedAt = now)),
            invitations =
                listOf(
                    PendingInvitation(Uuid.random(), "c.martin@exemple.fr", ListRole.Editor, now, now + SEVEN_DAYS),
                ),
        )

    var sent: SentInvitation = SentInvitation(Uuid.random(), "parcourses://invitation#token", sent = true, now)
    var received: List<ReceivedInvitation> = emptyList()
    var preview: InvitationPreview = InvitationPreview(status = "invalid")
    var acceptance: AcceptResult = AcceptResult(AcceptOutcome.Joined, listId.toString())

    /** Prochain échec, consommé par l'appel suivant. */
    var failure: InviteErrorKind? = null
    val calls = mutableListOf<String>()

    private fun enter(call: String) {
        calls += call
        failure?.let {
            failure = null
            throw SharingFailure(it)
        }
    }

    override suspend fun sendInvitation(
        listId: String,
        email: String,
        role: ListRole,
    ): SentInvitation {
        enter("send:$email:${role.wireName}")
        return sent
    }

    override suspend fun invitationLink(
        listId: String,
        email: String,
        role: ListRole,
    ): String {
        enter("link:$email")
        return "parcourses://invitation#fresh"
    }

    override suspend fun revokeInvitation(id: String) = enter("revoke:$id")

    override suspend fun listSharing(listId: String): ListSharing {
        enter("listSharing")
        return sharing
    }

    override suspend fun myInvitations(): List<ReceivedInvitation> {
        enter("myInvitations")
        return received
    }

    override suspend fun previewInvitation(token: String): InvitationPreview {
        enter("preview")
        return preview
    }

    override suspend fun acceptInvitation(token: String): AcceptResult {
        enter("acceptToken")
        return acceptance
    }

    override suspend fun acceptInvitation(id: Uuid): AcceptResult {
        enter("accept:$id")
        return acceptance
    }

    override suspend fun declineInvitation(id: Uuid) = enter("decline:$id")

    override suspend fun setMemberRole(
        listId: String,
        userId: String,
        role: ListRole,
    ) = enter("role:$userId:${role.wireName}")

    override suspend fun removeMember(
        listId: String,
        userId: String,
    ) = enter("remove:$userId")

    override suspend fun leaveList(listId: String) = enter("leave:$listId")

    companion object {
        val SEVEN_DAYS = kotlin.time.Duration.parse("7d")
    }
}
