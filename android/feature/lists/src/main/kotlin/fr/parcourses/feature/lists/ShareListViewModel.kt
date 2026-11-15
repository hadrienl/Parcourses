package fr.parcourses.feature.lists

import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.data.sharing.SharingFailure
import fr.parcourses.core.data.sharing.SharingService
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.ListParticipant
import fr.parcourses.core.network.dto.ListSharing
import fr.parcourses.core.network.dto.PendingInvitation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.Locale

/** Message bref de la feuille « Partager » (Snackbar, région live polie). */
sealed interface ShareMessage {
    data class Sent(
        val email: String,
    ) : ShareMessage

    data object Resent : ShareMessage

    /** Lien copié : [fresh] vrai si un nouveau jeton a remplacé celui de l'e-mail. */
    data class Copied(
        val fresh: Boolean,
    ) : ShareMessage

    data class RoleChanged(
        val name: String?,
        val role: ListRole,
    ) : ShareMessage

    /** Changer un accès demande le réseau, rien n'est mis en file. */
    data object MemberOffline : ShareMessage

    /** Une action sur un membre ou une invitation a échoué pour une autre raison. */
    data class Failed(
        val kind: InviteErrorKind,
    ) : ShareMessage
}

/** Chargement de `list_sharing`. */
enum class ShareLoad { Loading, Loaded, Offline, Failed }

@Immutable
data class ShareListUiState(
    val listName: String = "",
    val load: ShareLoad = ShareLoad.Loading,
    val sharing: ListSharing? = null,
    val role: ListRole = ListRole.Editor,
    val isSending: Boolean = false,
    /** Erreur liée au champ e-mail, avec l'adresse refusée (« … fait déjà partie de la liste »). */
    val emailError: InviteErrorKind? = null,
    val refusedEmail: String? = null,
    /** Invitation créée sans e-mail parti : le lien à donner soi-même. */
    val mailFailLink: String? = null,
    /** Membre ou invitation dont l'action est en cours (indicateur sur la ligne). */
    val busyId: String? = null,
    val message: ShareMessage? = null,
    /** Lien à copier dans le presse-papiers, consommé par l'écran. */
    val clip: String? = null,
    /** La personne a quitté la liste : l'écran se ferme, la liste aussi. */
    val left: Boolean = false,
    /** Mon rôle sur l'appareil (`lists.role`), le seul connu tant que `list_sharing` n'est pas lue. */
    val localRole: ListRole? = null,
) {
    /** Propriétaire : « Partager la liste » ; sinon la feuille « Membres », en lecture. */
    val isOwner: Boolean get() = sharing?.role == ListRole.Owner

    /**
     * Formulaire d'invitation et titre « Partager la liste » : le rôle lu par `list_sharing`, sinon le rôle local
     * (jamais « propriétaire » par défaut : un membre hors ligne voit « Membres »).
     */
    val showsOwnerSheet: Boolean get() = (sharing?.role ?: localRole) == ListRole.Owner
    val members: List<ListParticipant> get() = sharing?.participants.orEmpty()
    val invitations: List<PendingInvitation> get() = sharing?.invitations.orEmpty()
}

/**
 * Feuille « Partager la liste » (#87 §9.2, maquette §2) et feuille « Membres » d'un membre (§3). Tout demande le
 * réseau : rien n'est mis en file. Ouverte, elle se recharge sur les signaux `members` et `invitations` de sa liste.
 */
@Suppress("TooManyFunctions")
class ShareListViewModel(
    private val listId: String,
    private val service: SharingService,
    listName: Flow<String?> = emptyFlow(),
    /** Mon rôle local sur la liste (`lists.role`). */
    localRole: Flow<ListRole?> = emptyFlow(),
    /** Signaux temps réel : relire `list_sharing` (feuille ouverte). */
    reloads: Flow<Set<String>> = emptyFlow(),
    /** La feuille est ouverte (pour `RealtimeSignals.sharingSheetOpened`) ; appelé avec `false` à la fermeture. */
    private val onOpenChanged: (Boolean) -> Unit = {},
) : ViewModel() {
    private val state = MutableStateFlow(ShareListUiState())
    val uiState: StateFlow<ShareListUiState> = state.asStateFlow()

    /** Adresse à inviter, hissée ici pour survivre à la rotation. */
    val email = TextFieldState()

    init {
        onOpenChanged(true)
        viewModelScope.launch { listName.collect { name -> state.update { it.copy(listName = name.orEmpty()) } } }
        viewModelScope.launch { localRole.collect { role -> state.update { it.copy(localRole = role) } } }
        viewModelScope.launch { reloads.collect { ids -> if (listId in ids) reload(quiet = true) } }
        reload()
    }

    override fun onCleared() {
        onOpenChanged(false)
    }

    fun retry() = reload()

    fun selectRole(role: ListRole) = state.update { it.copy(role = role) }

    fun emailEdited() =
        state.update {
            if (it.emailError !=
                null
            ) {
                it.copy(emailError = null, refusedEmail = null)
            } else {
                it
            }
        }

    /** Contrôle local de la forme, puis `send-invitation`. La feuille reste ouverte pour inviter quelqu'un d'autre. */
    fun send() {
        val current = state.value
        if (current.isSending) return
        val address =
            email.text
                .toString()
                .trim()
                .lowercase(Locale.ROOT)
        if (!isValidEmail(address)) {
            state.update { it.copy(emailError = InviteErrorKind.InvalidEmail, refusedEmail = address) }
            return
        }
        state.update { it.copy(isSending = true, emailError = null, mailFailLink = null) }
        viewModelScope.launch {
            try {
                val sent = service.sendInvitation(listId, address, current.role)
                email.clearText()
                state.update {
                    it.copy(
                        isSending = false,
                        mailFailLink = sent.link.takeUnless { sent.sent },
                        message = ShareMessage.Sent(address).takeIf { sent.sent },
                    )
                }
                reload(quiet = true)
            } catch (e: SharingFailure) {
                state.update { it.copy(isSending = false, emailError = e.kind, refusedEmail = address) }
            }
        }
    }

    /** « Renvoyer » : nouveau jeton, nouvel e-mail, nouvelle échéance. */
    fun resend(invitation: PendingInvitation) =
        act(invitation.id.toString()) {
            val sent = service.sendInvitation(listId, invitation.email, invitation.role)
            state.update {
                it.copy(
                    message = ShareMessage.Resent.takeIf { sent.sent },
                    mailFailLink = sent.link.takeUnless { sent.sent },
                )
            }
        }

    /** « Copier le lien » : un nouveau jeton, sans e-mail ; celui de l'e-mail ne fonctionne plus. */
    fun copyLink(invitation: PendingInvitation) =
        act(invitation.id.toString()) {
            val link = service.invitationLink(listId, invitation.email, invitation.role)
            state.update { it.copy(clip = link, message = ShareMessage.Copied(fresh = true)) }
        }

    /** Carte « e-mail non parti » : le lien qui vient d'être créé. */
    fun copyMailFailLink() {
        val link = state.value.mailFailLink ?: return
        state.update { it.copy(clip = link, message = ShareMessage.Copied(fresh = false)) }
    }

    fun revoke(invitation: PendingInvitation) =
        act(invitation.id.toString()) {
            service.revokeInvitation(invitation.id.toString())
        }

    fun setRole(
        member: ListParticipant,
        role: ListRole,
    ) {
        if (member.role == role) return
        act(member.userId.toString()) {
            service.setMemberRole(listId, member.userId.toString(), role)
            state.update { it.copy(message = ShareMessage.RoleChanged(member.displayName, role)) }
        }
    }

    fun remove(member: ListParticipant) =
        act(member.userId.toString()) {
            service.removeMember(listId, member.userId.toString())
        }

    /** « Quitter la liste » : la liste disparaît de l'appareil, l'écran se ferme. */
    fun leave() =
        act(LEAVING, reloadAfter = false) {
            service.leaveList(listId)
            state.update { it.copy(left = true) }
        }

    fun messageShown() = state.update { it.copy(message = null) }

    fun clipConsumed() = state.update { it.copy(clip = null) }

    /** Action réseau sur une ligne : indicateur pendant l'appel, puis relecture. */
    private fun act(
        id: String,
        reloadAfter: Boolean = true,
        block: suspend () -> Unit,
    ) {
        if (state.value.busyId != null) return
        state.update { it.copy(busyId = id) }
        viewModelScope.launch {
            try {
                block()
                if (reloadAfter) reload(quiet = true)
            } catch (e: SharingFailure) {
                val message =
                    if (e.kind == InviteErrorKind.Offline) ShareMessage.MemberOffline else ShareMessage.Failed(e.kind)
                state.update { it.copy(message = message) }
            } finally {
                state.update { it.copy(busyId = null) }
            }
        }
    }

    /** [quiet] : relecture sur un signal ou après une action, sans repasser par l'état de chargement. */
    private fun reload(quiet: Boolean = false) {
        if (!quiet) state.update { it.copy(load = if (it.sharing == null) ShareLoad.Loading else it.load) }
        viewModelScope.launch {
            try {
                val sharing = service.listSharing(listId)
                state.update { it.copy(sharing = sharing, load = ShareLoad.Loaded) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: SharingFailure) {
                // Déjà chargée : on garde ce qu'on a, la prochaine relecture rattrapera.
                if (state.value.sharing == null) {
                    val load = if (e.kind == InviteErrorKind.Offline) ShareLoad.Offline else ShareLoad.Failed
                    state.update { it.copy(load = load) }
                }
            }
        }
    }

    companion object {
        private const val LEAVING = "leave"
        private val EMAIL = Regex("^[a-z0-9._%+-]+@[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}$")
        private const val MAX_EMAIL = 254

        /** Même forme que le serveur (`create_invitation`) : refusée ici, l'adresse ne part pas. */
        fun isValidEmail(address: String): Boolean = address.length <= MAX_EMAIL && EMAIL.matches(address)
    }
}
