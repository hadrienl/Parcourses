@file:UseSerializers(UuidSerializer::class, InstantSerializer::class)

package fr.parcourses.core.network.dto

import fr.parcourses.core.model.ListRole
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.UseSerializers
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlin.time.Instant
import kotlin.uuid.Uuid

// Partage d'une liste (#87, lot 87.6). Noms communs avec iOS : `shared/test-vectors/sharing/README.md`. Les réponses
// viennent des RPC du lot 87.2 (`list_sharing`, `my_invitations`, `preview_invitation`, `accept_invitation`) et de
// l'Edge Function `send-invitation`.

/** Rôle en texte (`owner`, `editor`, `viewer`). Un rôle inconnu de cette version est lu comme le plus restreint. */
internal object ListRoleSerializer : KSerializer<ListRole> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("fr.parcourses.ListRole", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): ListRole = ListRole.fromWire(decoder.decodeString()) ?: ListRole.Viewer

    override fun serialize(
        encoder: Encoder,
        value: ListRole,
    ) = encoder.encodeString(value.wireName)
}

/**
 * Une personne de la liste : le propriétaire ou un membre. Jamais d'adresse e-mail (#87 §8). Le propriétaire, dans
 * `list_sharing`, n'a ni `role` ni `joined_at` : [role] vaut alors [ListRole.Owner].
 */
@Serializable
data class ListParticipant(
    @SerialName("user_id") val userId: Uuid,
    @SerialName("display_name") val displayName: String? = null,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole = ListRole.Owner,
    @SerialName("is_me") val isMe: Boolean = false,
    @SerialName("joined_at") val joinedAt: Instant? = null,
)

/** Invitation encore vivante d'une liste, vue par son propriétaire seulement. [email] : l'adresse qu'il a saisie. */
@Serializable
data class PendingInvitation(
    val id: Uuid,
    val email: String,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("expires_at") val expiresAt: Instant,
    @SerialName("sent_count") val sentCount: Int = 0,
    val expired: Boolean = false,
)

/** Réponse de `list_sharing` : mon rôle, le propriétaire, les membres et, pour le propriétaire, les invitations. */
@Serializable
data class ListSharing(
    @SerialName("list_id") val listId: Uuid,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole,
    val owner: ListParticipant,
    val members: List<ListParticipant> = emptyList(),
    val invitations: List<PendingInvitation> = emptyList(),
) {
    /** Le propriétaire puis les membres, dans l'ordre d'arrivée. */
    val participants: List<ListParticipant> get() = listOf(owner.copy(role = ListRole.Owner)) + members
}

/** Une ligne de `my_invitations` : invitation adressée à mon adresse vérifiée, pour une liste dont je ne suis pas. */
@Serializable
data class ReceivedInvitation(
    val id: Uuid,
    @SerialName("list_id") val listId: Uuid,
    @SerialName("list_name") val listName: String,
    @SerialName("inviter_name") val inviterName: String? = null,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole,
    @SerialName("expires_at") val expiresAt: Instant,
)

/**
 * Colonnes de `preview_invitation` : ce que montre la carte d'une invitation ouverte par son lien. [listName] n'est
 * donné que si l'adresse est la bonne (ou si l'on est déjà membre) ; [status] : `pending`, `expired`, `used`,
 * `member`, `invalid`, `rate_limited` (entrée de `invitationCardState`).
 */
@Serializable
data class InvitationPreview(
    val status: String,
    @SerialName("invitation_id") val invitationId: Uuid? = null,
    @SerialName("list_id") val listId: Uuid? = null,
    @SerialName("list_name") val listName: String? = null,
    @SerialName("inviter_name") val inviterName: String? = null,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole? = null,
    @SerialName("email_matches") val emailMatches: Boolean? = null,
    @SerialName("invited_email_masked") val invitedEmailMasked: String? = null,
    @SerialName("expires_at") val expiresAt: Instant? = null,
)

/** Réponse de l'Edge Function `send-invitation`. [sent] faux : l'invitation existe, l'e-mail n'est pas parti. */
@Serializable
data class SentInvitation(
    @SerialName("invitation_id") val invitationId: Uuid,
    val link: String,
    val sent: Boolean,
    @SerialName("expires_at") val expiresAt: Instant,
)

/**
 * Réponse de `accept_invitation`. [status] (`accepted`, `member`, `used`, `expired`, `invalid`, `rate_limited`) est
 * l'entrée de `SharingDecisions.acceptOutcome` ; [listId] n'est donné que si l'on a accès à la liste.
 */
@Serializable
data class InvitationAcceptance(
    val status: String,
    @SerialName("list_id") val listId: Uuid? = null,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole? = null,
)

/** Ligne de `create_invitation` (« Copier le lien » : sans e-mail, nouveau jeton). */
@Serializable
internal data class CreatedInvitation(
    @SerialName("invitation_id") val invitationId: Uuid,
    @SerialName("invitee_email") val inviteeEmail: String,
    val token: String,
    @SerialName("expires_at") val expiresAt: Instant,
    @SerialName("sender_name") val senderName: String? = null,
)

/** Membre d'une liste (`list_members`, lue directement : RLS du propriétaire et des membres). */
@Serializable
data class ListMemberRow(
    @SerialName("list_id") val listId: Uuid,
    @SerialName("user_id") val userId: Uuid,
    @Serializable(with = ListRoleSerializer::class) val role: ListRole,
    @SerialName("added_by") val addedBy: Uuid? = null,
    @SerialName("created_at") val createdAt: Instant,
    @SerialName("updated_at") val updatedAt: Instant,
) {
    companion object {
        internal val spec = TableSpec("list_members", serializer())
    }
}

/** Corps d'erreur de l'Edge Function : `{ error, code }`. */
@Serializable
internal data class FunctionError(
    val error: String? = null,
    val code: String? = null,
)
