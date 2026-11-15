package fr.parcourses.core.data.sharing

import fr.parcourses.core.data.sync.SyncStore
import fr.parcourses.core.database.ParcoursesDatabase
import fr.parcourses.core.database.entity.ListParticipantEntity
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.RemoteError
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.SharingRequestError
import fr.parcourses.core.network.dto.InvitationAcceptance
import fr.parcourses.core.network.dto.InvitationPreview
import fr.parcourses.core.network.dto.ListSharing
import fr.parcourses.core.network.dto.ReceivedInvitation
import fr.parcourses.core.network.dto.SentInvitation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlin.uuid.Uuid

/** Échec d'une action du partage, déjà traduit en message de la maquette (vecteur `003`). */
class SharingFailure(
    val kind: InviteErrorKind,
    cause: Throwable? = null,
) : Exception(kind.wireName, cause)

/** Issue d'une acceptation : [listId] est la liste à ouvrir quand [AcceptOutcome.opensList]. */
data class AcceptResult(
    val outcome: AcceptOutcome,
    val listId: String?,
)

/**
 * Partage d'une liste (#87, lot 87.6), mêmes noms que la passerelle iOS (`shared/test-vectors/sharing/README.md`).
 * Tout demande le réseau et un compte e-mail : rien n'est mis en file. Un échec lève [SharingFailure].
 * Les personnes des listes viennent de la base (descente), pour les pastilles hors ligne.
 */
@Suppress("TooManyFunctions")
class SharingRepository(
    private val gateway: RemoteGateway?,
    private val db: ParcoursesDatabase,
    private val isOnline: () -> Boolean = { true },
    /** Descente complète, attendue (accès gagné : la liste est téléchargée avant d'être ouverte). */
    private val pull: suspend () -> Unit = {},
) {
    private val store = SyncStore(db)

    fun observeParticipants(listId: String): Flow<List<ListParticipantEntity>> = db.participants().observe(listId)

    fun observeAllParticipants(): Flow<List<ListParticipantEntity>> = db.participants().observeAll()

    /** Edge Function `send-invitation` : invitation créée (ou renouvelée) et envoyée. */
    suspend fun sendInvitation(
        listId: String,
        email: String,
        role: ListRole,
    ): SentInvitation = call { it.sendInvitation(Uuid.parse(listId), email.trim(), role) }

    /** « Copier le lien » : nouveau jeton sans e-mail, l'ancien lien ne marche plus. */
    suspend fun invitationLink(
        listId: String,
        email: String,
        role: ListRole,
    ): String = call { it.invitationLink(Uuid.parse(listId), email, role) }

    suspend fun revokeInvitation(id: String) = call { it.revokeInvitation(Uuid.parse(id)) }

    /** `list_sharing`, appliquée aussi à la base : personnes et rôle à jour pour la liste ouverte. */
    suspend fun listSharing(listId: String): ListSharing =
        call { it.listSharing(Uuid.parse(listId)) }.also { store.applySharing(it) }

    suspend fun myInvitations(): List<ReceivedInvitation> = call { it.myInvitations() }

    suspend fun previewInvitation(token: String): InvitationPreview = call { it.previewInvitation(token) }

    /** Par le lien (toute adresse confirmée, après avertissement). Liste accessible : descendue avant d'être rendue. */
    suspend fun acceptInvitation(token: String): AcceptResult = accepted(call { it.acceptInvitation(token) })

    /** Invitation retrouvée par l'adresse (`my_invitations`). */
    suspend fun acceptInvitation(id: Uuid): AcceptResult = accepted(call { it.acceptInvitation(id) })

    suspend fun declineInvitation(id: Uuid) = call { it.declineInvitation(id) }

    suspend fun setMemberRole(
        listId: String,
        userId: String,
        role: ListRole,
    ) = call { it.setMemberRole(Uuid.parse(listId), Uuid.parse(userId), role) }

    /** Retire un membre de la liste (propriétaire). */
    suspend fun removeMember(
        listId: String,
        userId: String,
    ) = call { it.removeMember(Uuid.parse(listId), Uuid.parse(userId)) }

    /** « Quitter la liste » : retrait de son propre compte, puis la liste quitte l'appareil avec ses entrées. */
    suspend fun leaveList(listId: String) {
        call { it.removeMember(Uuid.parse(listId), it.currentAccountId()) }
        store.removeLists(listOf(listId))
    }

    private suspend fun accepted(acceptance: InvitationAcceptance): AcceptResult {
        val outcome = SharingDecisions.acceptOutcome(acceptance.status)
        val listId = acceptance.listId?.toString()
        // Accès gagné : la liste est téléchargée entièrement (descente) avant d'être ouverte.
        if (outcome.opensList) runCatching { pull() }.onFailure { if (it is CancellationException) throw it }
        return AcceptResult(outcome, listId.takeIf { outcome.opensList })
    }

    @Suppress("TooGenericExceptionCaught") // toute panne devient un message de la maquette ; l'annulation est relancée
    private suspend fun <T> call(operation: suspend (RemoteGateway) -> T): T {
        val remote = gateway ?: throw SharingFailure(InviteErrorKind.Offline)
        if (!isOnline()) throw SharingFailure(InviteErrorKind.Offline)
        return try {
            operation(remote)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            throw SharingFailure(SharingDecisions.inviteErrorKind(errorOf(e)), e)
        }
    }

    private companion object {
        /** Entrée du vecteur `003` : message du serveur, `null` sans réponse. */
        fun errorOf(error: Exception): String? =
            when (error) {
                is SharingRequestError -> error.error
                is RemoteError.Network -> null
                is RemoteError.Forbidden -> "not allowed"
                is RemoteError.Unauthorized -> "unauthorized"
                else -> "rpc_failed"
            }
    }
}
