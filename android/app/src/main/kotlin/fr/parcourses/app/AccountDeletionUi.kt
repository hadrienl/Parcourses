package fr.parcourses.app

import android.util.Log
import androidx.annotation.StringRes
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.account.AccountDeletion
import fr.parcourses.core.data.account.AccountDeletionError
import fr.parcourses.core.data.account.AccountDeletionOutcome
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Où en est « Supprimer mes données » (#68), pour toute l'app : la suppression survit à l'écran qui l'a lancée. */
sealed interface AccountDeletionState {
    data object Idle : AccountDeletionState

    /** Voile « Suppression… », non annulable. */
    data object Running : AccountDeletionState

    /** « Vos données ont été supprimées. », par-dessus l'écran Listes vide. */
    data object Done : AccountDeletionState

    /** Relance sans session locale (C3) : l'appareil est vide, le serveur purgera le compte inactif. */
    data object DoneLocally : AccountDeletionState

    /** [retrySoon] : « Annuler » trop tôt après la dernière tentative (C2). */
    data class Failed(
        val error: AccountDeletionError,
        val retrySoon: Boolean = false,
    ) : AccountDeletionState
}

/**
 * Porte la suppression ([AccountDeletion]) dans [scope], celui de l'app : quitter À propos ne l'interrompt pas.
 * Une seule à la fois : un double appui ne lance rien de plus.
 */
class AccountDeletionController(
    private val deletion: AccountDeletion,
    private val scope: CoroutineScope,
) {
    private val current = MutableStateFlow<AccountDeletionState>(AccountDeletionState.Idle)
    val state: StateFlow<AccountDeletionState> = current.asStateFlow()

    /** Après confirmation, ou « Réessayer ». `false` si une suppression tourne déjà. */
    fun start(): Boolean = launch { deletion.run() }

    /**
     * Au lancement, si le drapeau existe : la suppression interrompue reprend, voile affiché. `true` dès que le
     * drapeau existe, même si une suppression tourne déjà : le lancement ne doit alors rien démarrer d'autre. Lit le
     * disque : jamais sur le fil principal.
     */
    fun resumeAtLaunch(): Boolean {
        if (!deletion.isPending) return false
        launch { deletion.resumePending() ?: AccountDeletionOutcome.Cancelled }
        return true
    }

    /** « Annuler », quand la suppression n'est pas confirmée. */
    fun cancel(): Boolean = launch { deletion.cancel() }

    /** Message lu et fermé. Le doute, lui, ne se ferme que par « Réessayer » ou « Annuler » (C5). */
    fun acknowledge() {
        current.update { if (it == AccountDeletionState.Running) it else AccountDeletionState.Idle }
    }

    private fun launch(work: suspend () -> AccountDeletionOutcome): Boolean {
        // Prise atomique du voile : de deux appels simultanés, un seul lance la suppression.
        while (true) {
            val seen = current.value
            if (seen == AccountDeletionState.Running) return false
            if (current.compareAndSet(seen, AccountDeletionState.Running)) break
        }
        scope.launch {
            // Le voile ne doit jamais rester, même sur une erreur que rien ne rattrape.
            var result: AccountDeletionState = AccountDeletionState.Failed(AccountDeletionError.Unknown)
            try {
                result = outcome(work)
            } finally {
                current.value = result
            }
        }
        return true
    }

    @Suppress("TooGenericExceptionCaught") // Le voile ne doit jamais rester : toute panne devient un doute.
    private suspend fun outcome(work: suspend () -> AccountDeletionOutcome): AccountDeletionState =
        try {
            when (val result = work()) {
                AccountDeletionOutcome.Deleted -> AccountDeletionState.Done
                AccountDeletionOutcome.DeletedLocally -> AccountDeletionState.DoneLocally
                AccountDeletionOutcome.Cancelled -> AccountDeletionState.Idle
                is AccountDeletionOutcome.Failed -> AccountDeletionState.Failed(result.error, result.retrySoon)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Suppression interrompue : ${e.javaClass.simpleName}")
            AccountDeletionState.Failed(AccountDeletionError.Unknown)
        }

    private companion object {
        const val TAG = "AccountDeletion"
    }
}

/** Section « Vos données » d'À propos. [localOnly] : build sans Supabase, l'appareil seul est purgé (§5.7). */
data class AccountDeletionUiState(
    val confirming: Boolean = false,
    /** Une visite est ouverte : la confirmation prévient que les courses seront interrompues. */
    val visitOpen: Boolean = false,
    val running: Boolean = false,
    val localOnly: Boolean = false,
)

data class AccountDeletionActions(
    val onRequest: () -> Unit = {},
    val onConfirm: () -> Unit = {},
    val onDismiss: () -> Unit = {},
)

/** Confirmation de la suppression, sur l'écran À propos. Le déroulé, lui, est porté par [AccountDeletionController]. */
class AccountDeletionViewModel(
    deletion: StateFlow<AccountDeletionState>,
    private val hasOpenVisit: suspend () -> Boolean,
    private val start: () -> Boolean,
    localOnly: Boolean,
) : ViewModel() {
    private val confirming = MutableStateFlow(false)
    private val visitOpen = MutableStateFlow(false)
    private var requesting = false

    val state: StateFlow<AccountDeletionUiState> =
        combine(deletion, confirming, visitOpen) { current, isConfirming, open ->
            val running = current == AccountDeletionState.Running
            AccountDeletionUiState(isConfirming && !running, open, running, localOnly)
        }.stateIn(viewModelScope, SharingStarted.Eagerly, AccountDeletionUiState(localOnly = localOnly))

    val actions = AccountDeletionActions(onRequest = ::request, onConfirm = ::confirm, onDismiss = ::dismiss)

    /** Un double appui n'ouvre qu'une confirmation. */
    private fun request() {
        if (requesting || confirming.value || state.value.running) return
        requesting = true
        viewModelScope.launch {
            try {
                // Lecture impossible : la confirmation s'ouvre quand même, sans la phrase sur les courses.
                visitOpen.value = runCatching { hasOpenVisit() }.getOrDefault(false)
                confirming.value = true
            } finally {
                requesting = false
            }
        }
    }

    /** Un double appui sur « Supprimer » ne lance qu'une suppression. */
    private fun confirm() {
        if (!confirming.compareAndSet(expect = true, update = false)) return
        start()
    }

    private fun dismiss() {
        confirming.value = false
    }
}

/** Contenu de la section « Vos données », sous son titre : phrase, bouton destructif, confirmation. */
@Composable
internal fun AccountDeletionContent(
    state: AccountDeletionUiState,
    actions: AccountDeletionActions,
) {
    val destructive = Ticket.colors.destructive
    Column {
        Text(
            stringResource(if (state.localOnly) R.string.about_account_body_local else R.string.about_account_body),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.ink,
            modifier = Modifier.fillMaxWidth().padding(horizontal = TicketDimens.spaceM, vertical = 2.dp),
        )
        OutlinedButton(
            onClick = actions.onRequest,
            enabled = !state.running,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = destructive),
            border = BorderStroke(1.dp, if (state.running) destructive.copy(alpha = DISABLED_ALPHA) else destructive),
            modifier =
                Modifier
                    .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
                    .heightIn(min = 48.dp)
                    .testTag(TAG_ACCOUNT_DELETE),
        ) { Text(stringResource(R.string.about_account_action)) }
    }
    if (state.confirming) {
        AlertDialog(
            onDismissRequest = actions.onDismiss,
            title = { Text(stringResource(R.string.about_account_confirm_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS)) {
                    val body =
                        if (state.localOnly) {
                            R.string.about_account_confirm_body_local
                        } else {
                            R.string.about_account_confirm_body
                        }
                    Text(stringResource(body))
                    if (state.visitOpen) Text(stringResource(R.string.about_account_confirm_visit))
                }
            },
            confirmButton = {
                TextButton(
                    onClick = actions.onConfirm,
                    colors = ButtonDefaults.textButtonColors(contentColor = destructive),
                    modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_ACCOUNT_DELETE_CONFIRM),
                ) { Text(stringResource(R.string.about_account_confirm_action)) }
            },
            dismissButton = {
                TextButton(
                    onClick = actions.onDismiss,
                    modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_ACCOUNT_DELETE_CANCEL),
                ) { Text(stringResource(R.string.about_account_cancel)) }
            },
        )
    }
}

/** Actions des messages de la suppression, quel que soit l'écran affiché. */
data class AccountDeletionOverlayActions(
    val onAcknowledge: () -> Unit = {},
    val onRetry: () -> Unit = {},
    val onCancel: () -> Unit = {},
)

/**
 * Par-dessus toute l'app : le voile « Suppression… » (bloquant, ni Retour ni appui à côté), puis le résultat. Le doute
 * ne se ferme que par « Réessayer » ou « Annuler » (C5). [localOnly] : build sans Supabase, rien sur « nos serveurs ».
 */
@Composable
internal fun AccountDeletionOverlay(
    state: AccountDeletionState,
    actions: AccountDeletionOverlayActions,
    localOnly: Boolean = false,
) {
    when (state) {
        AccountDeletionState.Idle -> {
            Unit
        }

        AccountDeletionState.Running -> {
            RunningVeil()
        }

        AccountDeletionState.Done -> {
            Message(null, R.string.about_account_done, actions.onAcknowledge)
        }

        AccountDeletionState.DoneLocally -> {
            Message(
                R.string.about_account_done_local_title,
                R.string.about_account_done_local_body,
                actions.onAcknowledge,
            )
        }

        is AccountDeletionState.Failed -> {
            when (state.error) {
                AccountDeletionError.Offline -> Message(null, R.string.about_account_offline, actions.onAcknowledge)
                AccountDeletionError.Refused -> Message(null, R.string.about_account_refused, actions.onAcknowledge)
                AccountDeletionError.Unknown -> Unconfirmed(state.retrySoon, localOnly, actions)
            }
        }
    }
}

@Composable
private fun RunningVeil() {
    Dialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
    ) {
        Surface(
            shape = MaterialTheme.shapes.large,
            color = Ticket.colors.paper,
            modifier = Modifier.testTag(TAG_ACCOUNT_RUNNING),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceM),
                modifier = Modifier.padding(TicketDimens.spaceL),
            ) {
                CircularProgressIndicator(modifier = Modifier.size(size = 24.dp), color = Ticket.colors.ink)
                Text(
                    stringResource(R.string.about_account_running),
                    style = MaterialTheme.typography.bodyLarge,
                    color = Ticket.colors.ink,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        }
    }
}

@Composable
private fun Message(
    @StringRes title: Int?,
    @StringRes text: Int,
    onAcknowledge: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onAcknowledge,
        // Le type attendu (lambda composable) passe dans les branches du `if`.
        title = if (title != null) ({ Text(stringResource(title)) }) else null,
        text = {
            Text(
                stringResource(text),
                modifier = Modifier.testTag(TAG_ACCOUNT_MESSAGE).semantics { liveRegion = LiveRegionMode.Polite },
            )
        },
        confirmButton = {
            TextButton(onClick = onAcknowledge, modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_ACCOUNT_OK)) {
                Text(stringResource(R.string.about_account_ok))
            }
        },
    )
}

/** Doute (C5, C6) : ni Retour ni appui à côté ; « Réessayer » ou « Annuler », rien d'autre. */
@Composable
private fun Unconfirmed(
    retrySoon: Boolean,
    localOnly: Boolean,
    actions: AccountDeletionOverlayActions,
) {
    AlertDialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        title = { Text(stringResource(R.string.about_account_unconfirmed_title)) },
        text = {
            Column(
                verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
                modifier = Modifier.testTag(TAG_ACCOUNT_MESSAGE).semantics { liveRegion = LiveRegionMode.Polite },
            ) {
                val body =
                    if (localOnly) {
                        R.string.about_account_unconfirmed_body_local
                    } else {
                        R.string.about_account_unconfirmed_body
                    }
                Text(stringResource(body))
                if (retrySoon) Text(stringResource(R.string.about_account_retry_soon))
            }
        },
        confirmButton = {
            TextButton(
                onClick = actions.onRetry,
                modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_ACCOUNT_RETRY),
            ) { Text(stringResource(R.string.about_account_retry)) }
        },
        dismissButton = {
            TextButton(
                onClick = actions.onCancel,
                modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_ACCOUNT_UNCONFIRMED_CANCEL),
            ) { Text(stringResource(R.string.about_account_cancel)) }
        },
    )
}

/** Opacité Material d'un élément désactivé. */
private const val DISABLED_ALPHA = 0.38f

internal const val TAG_ACCOUNT_DELETE = "about-account-delete"
internal const val TAG_ACCOUNT_DELETE_CONFIRM = "about-account-delete-confirm"
internal const val TAG_ACCOUNT_DELETE_CANCEL = "about-account-delete-cancel"
internal const val TAG_ACCOUNT_RUNNING = "account-deletion-running"
internal const val TAG_ACCOUNT_MESSAGE = "account-deletion-message"
internal const val TAG_ACCOUNT_OK = "account-deletion-ok"
internal const val TAG_ACCOUNT_RETRY = "account-deletion-retry"
internal const val TAG_ACCOUNT_UNCONFIRMED_CANCEL = "account-deletion-unconfirmed-cancel"
