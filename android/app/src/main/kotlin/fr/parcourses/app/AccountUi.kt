package fr.parcourses.app

import android.util.Log
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountSession
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountSignOutOutcome
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.sync.AccountKind
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

/** Où en est « Se déconnecter » (#87 §2.4), pour toute l'app : elle survit à l'écran qui l'a lancée. */
sealed interface AccountSignOutState {
    data object Idle : AccountSignOutState

    /** Voile « Déconnexion… », non annulable. */
    data object Running : AccountSignOutState

    data class Failed(
        val error: AccountSignOutError,
    ) : AccountSignOutState
}

/** Porte la déconnexion ([AccountSignOut]) dans [scope], celui de l'app. Une seule à la fois. */
class AccountSignOutController(
    private val signOut: AccountSignOut,
    private val scope: CoroutineScope,
) {
    private val current = MutableStateFlow<AccountSignOutState>(AccountSignOutState.Idle)
    val state: StateFlow<AccountSignOutState> = current.asStateFlow()

    /** Après confirmation. `false` si une déconnexion tourne déjà. */
    fun start(): Boolean {
        while (true) {
            val seen = current.value
            if (seen == AccountSignOutState.Running) return false
            if (current.compareAndSet(seen, AccountSignOutState.Running)) break
        }
        scope.launch {
            var result: AccountSignOutState = AccountSignOutState.Failed(AccountSignOutError.Unknown)
            try {
                result = outcome()
            } finally {
                current.value = result
            }
        }
        return true
    }

    fun acknowledge() {
        current.update { if (it == AccountSignOutState.Running) it else AccountSignOutState.Idle }
    }

    @Suppress("TooGenericExceptionCaught") // Le voile ne doit jamais rester : toute panne devient un échec.
    private suspend fun outcome(): AccountSignOutState =
        try {
            when (val result = signOut.run()) {
                AccountSignOutOutcome.SignedOut -> AccountSignOutState.Idle
                is AccountSignOutOutcome.Failed -> AccountSignOutState.Failed(result.error)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "Déconnexion interrompue : ${e.javaClass.simpleName}")
            AccountSignOutState.Failed(AccountSignOutError.Unknown)
        }

    private companion object {
        const val TAG = "AccountSignOut"
    }
}

/** Section « Compte » d'À propos. [visible] : faux sans Supabase (rien à quoi se connecter). */
data class AccountUiState(
    val visible: Boolean = false,
    val account: AccountState = AccountState(),
    val confirmingSignOut: Boolean = false,
    val signingOut: Boolean = false,
    val editingName: Boolean = false,
    val nameSaveFailed: Boolean = false,
)

data class AccountActions(
    val onSignIn: () -> Unit = {},
    val onSignOutRequest: () -> Unit = {},
    val onSignOutConfirm: () -> Unit = {},
    val onSignOutDismiss: () -> Unit = {},
    val onEditName: () -> Unit = {},
    val onSaveName: (String) -> Unit = {},
    val onDismissName: () -> Unit = {},
)

/** Section « Compte » : état du compte ([AccountSession]), prénom, déconnexion ([AccountSignOutController]). */
class AccountViewModel(
    private val session: AccountSession?,
    private val signOut: AccountSignOutController?,
    onSignIn: () -> Unit,
) : ViewModel() {
    private val confirming = MutableStateFlow(false)
    private val editing = MutableStateFlow(false)
    private val saveFailed = MutableStateFlow(false)
    private val accountFlow = session?.state ?: MutableStateFlow(AccountState())
    private val signOutFlow = signOut?.state ?: MutableStateFlow(AccountSignOutState.Idle)

    val state: StateFlow<AccountUiState> =
        combine(accountFlow, signOutFlow, confirming, editing, saveFailed) { account, out, confirm, edit, failed ->
            val running = out == AccountSignOutState.Running
            AccountUiState(
                visible = session != null,
                account = account,
                confirmingSignOut = confirm && !running,
                signingOut = running,
                editingName = edit,
                nameSaveFailed = failed,
            )
        }.stateIn(viewModelScope, SharingStarted.Eagerly, AccountUiState(visible = session != null))

    val actions =
        AccountActions(
            onSignIn = onSignIn,
            onSignOutRequest = { confirming.value = true },
            onSignOutConfirm = ::confirmSignOut,
            onSignOutDismiss = { confirming.value = false },
            onEditName = {
                saveFailed.value = false
                editing.value = true
            },
            onSaveName = ::saveName,
            onDismissName = { editing.value = false },
        )

    init {
        // Adresse lue dans la session, prénom relu sur le serveur à l'ouverture d'À propos.
        viewModelScope.launch { session?.refresh() }
    }

    private fun confirmSignOut() {
        if (!confirming.compareAndSet(expect = true, update = false)) return
        signOut?.start()
    }

    private fun saveName(value: String) {
        val model = session ?: return
        viewModelScope.launch {
            val saved = model.setDisplayName(value)
            saveFailed.value = !saved
            if (saved) editing.value = false
        }
    }
}

/** Contenu de la section « Compte », sous son titre. */
@Composable
internal fun AccountContent(
    state: AccountUiState,
    actions: AccountActions,
) {
    val colors = Ticket.colors
    Column {
        if (state.account.kind == AccountKind.Email) {
            EmailAccountContent(state, actions)
        } else {
            Text(
                stringResource(R.string.account_anonymous_body),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.ink,
                modifier = Modifier.fillMaxWidth().padding(horizontal = TicketDimens.spaceM, vertical = 2.dp),
            )
            OutlinedButton(
                onClick = actions.onSignIn,
                modifier =
                    Modifier
                        .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
                        .heightIn(min = TicketDimens.touchMin)
                        .testTag(TAG_ACCOUNT_SIGN_IN),
            ) { Text(stringResource(R.string.account_sign_in)) }
        }
    }
    if (state.confirmingSignOut) SignOutConfirmation(actions)
    if (state.editingName) NameDialog(state, actions)
}

/** Compte e-mail : adresse, prénom modifiable, note de confidentialité, « Se déconnecter ». */
@Composable
private fun EmailAccountContent(
    state: AccountUiState,
    actions: AccountActions,
) {
    val colors = Ticket.colors
    AccountRow(stringResource(R.string.account_email), state.account.email.orEmpty(), Modifier)
    val name = state.account.displayName ?: stringResource(R.string.account_name_missing)
    val editLabel = stringResource(R.string.account_name_edit)
    AccountRow(
        stringResource(R.string.account_name),
        name,
        Modifier
            .clickable(onClickLabel = editLabel, onClick = actions.onEditName)
            .testTag(TAG_ACCOUNT_NAME),
        trailingEdit = true,
    )
    Row(
        modifier = Modifier.padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Outlined.Lock,
            contentDescription = null,
            tint = colors.inkMuted,
            modifier = Modifier.size(size = 16.dp),
        )
        Text(
            stringResource(R.string.account_note),
            style = MaterialTheme.typography.bodySmall,
            color = colors.inkMuted,
        )
    }
    OutlinedButton(
        onClick = actions.onSignOutRequest,
        enabled = !state.signingOut,
        modifier =
            Modifier
                .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
                .heightIn(min = TicketDimens.touchMin)
                .testTag(TAG_ACCOUNT_SIGN_OUT),
    ) { Text(stringResource(R.string.account_sign_out)) }
}

@Composable
private fun AccountRow(
    label: String,
    value: String,
    modifier: Modifier,
    trailingEdit: Boolean = false,
) {
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.rowMin)
                .padding(horizontal = TicketDimens.spaceM),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // Une seule annonce pour le libellé et la valeur.
        Column(Modifier.weight(1f).semantics(mergeDescendants = true) {}) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = Ticket.colors.inkMuted)
            Text(value, style = MaterialTheme.typography.bodyLarge, color = Ticket.colors.ink)
        }
        if (trailingEdit) Icon(Icons.Default.Edit, contentDescription = null, tint = Ticket.colors.inkMuted)
    }
}

@Composable
private fun SignOutConfirmation(actions: AccountActions) {
    AlertDialog(
        onDismissRequest = actions.onSignOutDismiss,
        title = { Text(stringResource(R.string.account_sign_out_title)) },
        text = { Text(stringResource(R.string.account_sign_out_body)) },
        confirmButton = {
            TextButton(
                onClick = actions.onSignOutConfirm,
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_ACCOUNT_SIGN_OUT_CONFIRM),
            ) { Text(stringResource(R.string.account_sign_out), color = Ticket.colors.destructive) }
        },
        dismissButton = {
            TextButton(onClick = actions.onSignOutDismiss, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
                Text(stringResource(R.string.account_cancel))
            }
        },
    )
}

@Composable
private fun NameDialog(
    state: AccountUiState,
    actions: AccountActions,
) {
    var name by rememberSaveable { mutableStateOf(state.account.displayName.orEmpty()) }
    val valid = AccountLink.cleanedDisplayName(name) != null
    AlertDialog(
        onDismissRequest = actions.onDismissName,
        title = { Text(stringResource(R.string.link_name_label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
                Text(stringResource(R.string.link_name_help))
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.link_name_label)) },
                    singleLine = true,
                    isError = name.isNotEmpty() && !valid,
                    supportingText =
                        if (name.isNotEmpty() && !valid) {
                            { Text(stringResource(R.string.link_name_error)) }
                        } else {
                            null
                        },
                    keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .semantics { contentType = ContentType.PersonFirstName }
                            .testTag(TAG_ACCOUNT_NAME_FIELD),
                )
                if (state.nameSaveFailed) {
                    Text(
                        stringResource(R.string.account_name_save_failed),
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = { actions.onSaveName(name) },
                enabled = valid,
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_ACCOUNT_NAME_SAVE),
            ) { Text(stringResource(R.string.link_done_cta)) }
        },
        dismissButton = {
            TextButton(onClick = actions.onDismissName, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
                Text(stringResource(R.string.account_cancel))
            }
        },
    )
}

/** Par-dessus toute l'app : voile « Déconnexion… », puis le message d'échec. */
@Composable
internal fun AccountSignOutOverlay(
    state: AccountSignOutState,
    onAcknowledge: () -> Unit,
) {
    when (state) {
        AccountSignOutState.Idle -> {
            Unit
        }

        AccountSignOutState.Running -> {
            Dialog(
                onDismissRequest = {},
                properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
            ) {
                Surface(shape = MaterialTheme.shapes.large, color = Ticket.colors.paper) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceM),
                        modifier = Modifier.padding(TicketDimens.spaceL).testTag(TAG_SIGN_OUT_RUNNING),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(size = 24.dp), color = Ticket.colors.ink)
                        Text(
                            stringResource(R.string.account_sign_out_running),
                            style = MaterialTheme.typography.bodyLarge,
                            color = Ticket.colors.ink,
                            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                        )
                    }
                }
            }
        }

        is AccountSignOutState.Failed -> {
            val text =
                when (state.error) {
                    AccountSignOutError.Offline -> R.string.account_sign_out_offline
                    AccountSignOutError.Unsynced -> R.string.account_sign_out_unsynced
                    AccountSignOutError.Unknown -> R.string.account_sign_out_failed
                }
            AlertDialog(
                onDismissRequest = onAcknowledge,
                text = {
                    Text(
                        stringResource(text),
                        modifier =
                            Modifier
                                .testTag(
                                    TAG_SIGN_OUT_MESSAGE,
                                ).semantics { liveRegion = LiveRegionMode.Polite },
                    )
                },
                confirmButton = {
                    TextButton(onClick = onAcknowledge, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
                        Text(stringResource(R.string.account_ok))
                    }
                },
            )
        }
    }
}

internal const val TAG_ACCOUNT_SIGN_IN = "about-account-sign-in"
internal const val TAG_ACCOUNT_SIGN_OUT = "about-account-sign-out"
internal const val TAG_ACCOUNT_SIGN_OUT_CONFIRM = "about-account-sign-out-confirm"
internal const val TAG_ACCOUNT_NAME = "about-account-name"
internal const val TAG_ACCOUNT_NAME_FIELD = "about-account-name-field"
internal const val TAG_ACCOUNT_NAME_SAVE = "about-account-name-save"
internal const val TAG_SIGN_OUT_RUNNING = "account-sign-out-running"
internal const val TAG_SIGN_OUT_MESSAGE = "account-sign-out-message"
