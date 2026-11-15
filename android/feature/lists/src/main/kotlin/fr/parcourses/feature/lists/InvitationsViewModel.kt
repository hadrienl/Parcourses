package fr.parcourses.feature.lists

import androidx.compose.runtime.Immutable
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.sharing.AcceptOutcome
import fr.parcourses.core.data.sharing.InvitationCardState
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.data.sharing.SharingFailure
import fr.parcourses.core.data.sharing.SharingService
import fr.parcourses.core.network.dto.InvitationPreview
import fr.parcourses.core.network.dto.ReceivedInvitation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Erreur d'une acceptation, montrée sous la carte ; les boutons restent actifs. */
enum class InvitationError { Offline, Failed }

@Immutable
data class InvitationsUiState(
    val invitations: List<ReceivedInvitation> = emptyList(),
    /** Invitation en cours d'acceptation : ses boutons laissent place à « Ouverture de la liste… ». */
    val accepting: String? = null,
    val error: Pair<String, InvitationError>? = null,
    /** Message bref après une acceptation sans liste à ouvrir (expirée, déjà utilisée). */
    val outcome: AcceptOutcome? = null,
    /** Liste à ouvrir, consommée par la navigation. */
    val openList: String? = null,
)

/**
 * Invitations reçues (#87 §1.2, maquette §5) : `my_invitations()` à l'ouverture de « Mes listes », après une connexion
 * et sur un signal `invitations`. Compte e-mail seulement : un anonyme n'en a pas. Accepter = descente de la liste,
 * puis elle s'ouvre.
 */
class InvitationsViewModel(
    private val service: SharingService?,
    isEmailAccount: Flow<Boolean> = flowOf(false),
    reloads: Flow<Unit> = emptyFlow(),
) : ViewModel() {
    private val state = MutableStateFlow(InvitationsUiState())
    val uiState: StateFlow<InvitationsUiState> = state.asStateFlow()

    @Volatile
    private var email = false

    init {
        viewModelScope.launch {
            isEmailAccount.distinctUntilChanged().collect { isEmail ->
                email = isEmail
                if (isEmail) reload() else state.update { it.copy(invitations = emptyList()) }
            }
        }
        viewModelScope.launch { reloads.collect { if (email) reload() } }
    }

    /** Relecture silencieuse : hors ligne, la liste affichée reste. */
    fun reload() {
        val remote = service ?: return
        viewModelScope.launch {
            try {
                val received = remote.myInvitations()
                state.update { it.copy(invitations = received) }
            } catch (_: SharingFailure) {
                // Rien à montrer : l'entrée « Invitations » garde son dernier état.
            }
        }
    }

    fun accept(invitation: ReceivedInvitation) {
        val remote = service ?: return
        if (state.value.accepting != null) return
        val id = invitation.id.toString()
        state.update { it.copy(accepting = id, error = null) }
        viewModelScope.launch {
            try {
                val result = remote.acceptInvitation(invitation.id)
                state.update { current ->
                    current.copy(
                        accepting = null,
                        invitations = current.invitations.filterNot { it.id == invitation.id },
                        openList = result.listId,
                        outcome = result.outcome.takeUnless { it.opensList },
                    )
                }
            } catch (e: SharingFailure) {
                val error = if (e.kind == InviteErrorKind.Offline) InvitationError.Offline else InvitationError.Failed
                state.update { it.copy(accepting = null, error = id to error) }
            }
        }
    }

    /** Refus confirmé : définitif côté serveur, la carte disparaît. */
    fun decline(invitation: ReceivedInvitation) {
        val remote = service ?: return
        viewModelScope.launch {
            try {
                remote.declineInvitation(invitation.id)
                state.update { current -> current.copy(invitations = current.invitations.filterNot { it.id == invitation.id }) }
            } catch (e: SharingFailure) {
                val error = if (e.kind == InviteErrorKind.Offline) InvitationError.Offline else InvitationError.Failed
                state.update { it.copy(error = invitation.id.toString() to error) }
            }
        }
    }

    fun listOpened() = state.update { it.copy(openList = null) }

    fun outcomeShown() = state.update { it.copy(outcome = null) }
}

/** Carte d'une invitation ouverte par son lien (`preview_invitation`). */
@Immutable
data class InvitationLinkUiState(
    val loading: Boolean = true,
    val preview: InvitationPreview? = null,
    val card: InvitationCardState? = null,
    /** Adresse du compte connecté, pour l'avertissement « autre adresse ». */
    val accountEmail: String? = null,
    val accepting: Boolean = false,
    val error: InvitationError? = null,
    val outcome: AcceptOutcome? = null,
    val openList: String? = null,
    /** Jeton absent (processus relancé, lien illisible) : rien à montrer d'autre que « n'est plus valable ». */
    val missing: Boolean = false,
)

/**
 * Invitation ouverte par `parcourses://invitation#<jeton>` (#87 §1.3) : le jeton reste en mémoire, jamais écrit sur le
 * disque. Compte e-mail seulement : un anonyme passe d'abord par la connexion.
 */
class InvitationLinkViewModel(
    private val token: String?,
    private val service: SharingService?,
    private val accountEmail: suspend () -> String? = { null },
) : ViewModel() {
    private val state = MutableStateFlow(InvitationLinkUiState())
    val uiState: StateFlow<InvitationLinkUiState> = state.asStateFlow()

    init {
        load()
    }

    fun retry() = load()

    private fun load() {
        val remote = service
        if (token == null || remote == null) {
            state.update { it.copy(loading = false, missing = true, card = InvitationCardState.Invalid) }
            return
        }
        state.update { it.copy(loading = true, error = null) }
        viewModelScope.launch {
            try {
                val preview = remote.previewInvitation(token)
                val card = SharingDecisions.invitationCardState(preview.status, preview.emailMatches == true)
                state.update {
                    it.copy(loading = false, preview = preview, card = card, accountEmail = accountEmail())
                }
                // Déjà membre : acceptation idempotente, la liste s'ouvre.
                if (card == InvitationCardState.AlreadyMember) accept()
            } catch (e: SharingFailure) {
                val error = if (e.kind == InviteErrorKind.Offline) InvitationError.Offline else InvitationError.Failed
                state.update { it.copy(loading = false, error = error) }
            }
        }
    }

    fun accept() {
        val remote = service ?: return
        val link = token ?: return
        if (state.value.accepting) return
        state.update { it.copy(accepting = true, error = null) }
        viewModelScope.launch {
            try {
                val result = remote.acceptInvitation(link)
                val card =
                    when (result.outcome) {
                        AcceptOutcome.Used -> InvitationCardState.Used
                        AcceptOutcome.Expired -> InvitationCardState.Expired
                        AcceptOutcome.Invalid -> InvitationCardState.Invalid
                        AcceptOutcome.RateLimited -> InvitationCardState.RateLimited
                        AcceptOutcome.Joined, AcceptOutcome.AlreadyMember -> state.value.card
                    }
                state.update {
                    it.copy(accepting = false, card = card, outcome = result.outcome, openList = result.listId)
                }
            } catch (e: SharingFailure) {
                val error = if (e.kind == InviteErrorKind.Offline) InvitationError.Offline else InvitationError.Failed
                state.update { it.copy(accepting = false, error = error) }
            }
        }
    }

    fun listOpened() = state.update { it.copy(openList = null) }
}
