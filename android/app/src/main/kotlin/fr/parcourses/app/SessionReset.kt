package fr.parcourses.app

import android.util.Log
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Étapes de « Réinitialiser la session ». */
enum class SessionResetPhase { Idle, Confirming, Running, Done, Failed }

/**
 * Section « Session » d'À propos. [visible] : le stockage chiffré reste illisible, ou une réinitialisation est en
 * cours ou vient de finir (son résultat reste affiché jusqu'au départ de l'écran).
 */
data class SessionResetUiState(
    val visible: Boolean = false,
    val phase: SessionResetPhase = SessionResetPhase.Idle,
)

/** Actions de la section « Session ». */
data class SessionResetActions(
    val onRequest: () -> Unit = {},
    val onConfirm: () -> Unit = {},
    val onDismiss: () -> Unit = {},
)

/**
 * Sortie de secours quand la clé de session reste illisible (#51) : la personne confirme, puis [reset] oublie la
 * session et en crée une nouvelle. Les listes de l'appareil sont conservées et réidentifiées pour le nouveau compte.
 */
class SessionResetViewModel(
    isStuck: StateFlow<Boolean>,
    /** `false` si la clé s'ouvre de nouveau : rien n'a été réinitialisé. */
    private val reset: suspend () -> Boolean,
) : ViewModel() {
    private val phase = MutableStateFlow(SessionResetPhase.Idle)

    val state: StateFlow<SessionResetUiState> =
        combine(isStuck, phase) { stuck, current ->
            // Un échec ne garde la section que tant que le stockage reste bloqué.
            val inProgress = current != SessionResetPhase.Idle && current != SessionResetPhase.Failed
            SessionResetUiState(visible = stuck || inProgress, phase = current)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, SessionResetUiState())

    val actions =
        SessionResetActions(
            onRequest = {
                phase.update {
                    if (it == SessionResetPhase.Idle ||
                        it == SessionResetPhase.Failed
                    ) {
                        SessionResetPhase.Confirming
                    } else {
                        it
                    }
                }
            },
            onConfirm = ::confirm,
            onDismiss = { phase.compareAndSet(SessionResetPhase.Confirming, SessionResetPhase.Idle) },
        )

    private fun confirm() {
        if (!phase.compareAndSet(SessionResetPhase.Confirming, SessionResetPhase.Running)) return
        viewModelScope.launch {
            phase.value =
                try {
                    if (reset()) SessionResetPhase.Done else SessionResetPhase.Idle
                } catch (e: CancellationException) {
                    throw e
                } catch (e: RemoteError) {
                    // Le code seul : ni jeton ni donnée de l'utilisateur.
                    Log.i(TAG, "Réinitialisation de la session impossible : ${e.message}")
                    SessionResetPhase.Failed
                }
        }
    }

    private companion object {
        const val TAG = "SessionReset"
    }
}

/** Contenu de la section « Session », sous son titre : explication, bouton, résultat, confirmation. */
@Composable
internal fun SessionResetContent(
    state: SessionResetUiState,
    actions: SessionResetActions,
) {
    Column {
        val message =
            when (state.phase) {
                SessionResetPhase.Done -> R.string.about_session_done
                SessionResetPhase.Failed -> R.string.about_session_failed
                else -> R.string.about_session_body
            }
        Text(
            stringResource(message),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.ink,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = TicketDimens.spaceM, vertical = 2.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite },
        )
        if (state.phase != SessionResetPhase.Done) {
            OutlinedButton(
                onClick = actions.onRequest,
                enabled = state.phase != SessionResetPhase.Running,
                modifier =
                    Modifier
                        .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
                        .heightIn(min = 48.dp)
                        .testTag(TAG_SESSION_RESET),
            ) { Text(stringResource(R.string.about_session_action)) }
        }
    }
    if (state.phase == SessionResetPhase.Confirming) {
        AlertDialog(
            onDismissRequest = actions.onDismiss,
            title = { Text(stringResource(R.string.about_session_confirm_title)) },
            text = { Text(stringResource(R.string.about_session_confirm_body)) },
            confirmButton = {
                TextButton(
                    onClick = actions.onConfirm,
                    modifier = Modifier.testTag(TAG_SESSION_RESET_CONFIRM),
                ) { Text(stringResource(R.string.about_session_confirm_action), color = Ticket.colors.destructive) }
            },
            dismissButton = {
                TextButton(onClick = actions.onDismiss) { Text(stringResource(R.string.about_session_cancel)) }
            },
        )
    }
}

internal const val TAG_SESSION_RESET = "about-session-reset"
internal const val TAG_SESSION_RESET_CONFIRM = "about-session-reset-confirm"
