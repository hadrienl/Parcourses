package fr.parcourses.app

import android.util.Log
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.LocalContext
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
import fr.parcourses.core.data.account.PurgeFailure
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOf
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

    /**
     * Avant la confirmation : file envoyée, synchronisation arrêtée, modifications restantes comptées, puis [onReady]
     * (hors du fil principal).
     */
    fun prepare(
        onReady: (Int) -> Unit,
        onFailed: () -> Unit = {},
    ) {
        // Dans le scope de l'app : la synchro arrêtée par `prepare` est toujours reprise, par `abandon` ou `start`.
        scope.launch { signOut.prepare()?.let(onReady) ?: onFailed() }
    }

    /** Confirmation fermée : la synchronisation reprend, après la fin de `prepare` (même verrou). */
    fun abandon() {
        scope.launch { signOut.abandon() }
    }

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

    /** Au lancement, si le drapeau existe : la purge reprend, voile affiché. Lit le disque : hors du fil principal. */
    fun resumeAtLaunch(): Boolean {
        if (!signOut.isPending) return false
        start()
        return true
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

/** Écran Compte (#108) : un compte e-mail, son prénom, sa déconnexion. */
data class AccountUiState(
    val account: AccountState = AccountState(),
    val confirmingSignOut: Boolean = false,
    /** Modifications pas encore envoyées, comptées à la demande : la confirmation prévient qu'elles seront perdues. */
    val unsentChanges: Int = 0,
    val signingOut: Boolean = false,
    val editingName: Boolean = false,
    val nameSaveFailed: Boolean = false,
    /**
     * Changement de compte bloqué (#129) : `account.switch` laissé par un rejeu en échec, seuil franchi. Non nul, le
     * bandeau « Changement de compte inachevé » s'affiche ; son code va dans l'objet de « Nous écrire ».
     */
    val switchBlocked: PurgeFailure? = null,
)

data class AccountActions(
    /** « Se reconnecter », quand la session a disparu. */
    val onSignIn: () -> Unit = {},
    val onSignOutRequest: () -> Unit = {},
    val onSignOutConfirm: () -> Unit = {},
    val onSignOutDismiss: () -> Unit = {},
    val onEditName: () -> Unit = {},
    val onSaveName: (String) -> Unit = {},
    val onDismissName: () -> Unit = {},
    /** « Réessayer » du bandeau « Changement de compte inachevé » : rejeu, puis synchronisation s'il aboutit. */
    val onRetrySwitch: () -> Unit = {},
)

/**
 * Écran Compte : état du compte ([AccountSession]), prénom, déconnexion ([AccountSignOutController]), changement de
 * compte bloqué ([AccountSession.blockedSwitch], [onRetrySwitch]).
 */
class AccountViewModel(
    private val session: AccountSession?,
    private val signOut: AccountSignOutController?,
    onSignIn: () -> Unit,
    onRetrySwitch: () -> Unit = {},
) : ViewModel() {
    private val confirming = MutableStateFlow(false)
    private val unsent = MutableStateFlow(0)
    private val editing = MutableStateFlow(false)
    private val saveFailed = MutableStateFlow(false)
    private val accountFlow = session?.state ?: MutableStateFlow(AccountState())
    private val signOutFlow = signOut?.state ?: MutableStateFlow(AccountSignOutState.Idle)
    private val blockedSwitchFlow = session?.blockedSwitch ?: flowOf(null)
    private val withSwitch = combine(accountFlow, blockedSwitchFlow, ::Pair)

    val state: StateFlow<AccountUiState> =
        combine(withSwitch, signOutFlow, confirming, editing, saveFailed) { both, out, confirm, edit, failed ->
            val (account, blocked) = both
            val running = out == AccountSignOutState.Running
            AccountUiState(
                account = account,
                confirmingSignOut = confirm && !running,
                unsentChanges = unsent.value,
                signingOut = running,
                editingName = edit,
                nameSaveFailed = failed,
                switchBlocked = blocked,
            )
        }.stateIn(viewModelScope, SharingStarted.Eagerly, AccountUiState())

    val actions =
        AccountActions(
            onSignIn = onSignIn,
            onSignOutRequest = ::requestSignOut,
            onSignOutConfirm = ::confirmSignOut,
            onSignOutDismiss = ::dismissSignOut,
            onEditName = {
                saveFailed.value = false
                editing.value = true
            },
            onSaveName = ::saveName,
            onDismissName = { editing.value = false },
            onRetrySwitch = onRetrySwitch,
        )

    init {
        // Adresse lue dans la session, prénom relu sur le serveur à l'ouverture de l'écran Compte.
        viewModelScope.launch { session?.refresh() }
    }

    /** Compte d'abord ce qui n'est pas parti (synchronisation arrêtée), puis ouvre la confirmation. */
    private fun requestSignOut() {
        val controller = signOut ?: return
        if (confirming.value || prepared.value) return
        prepared.value = true
        controller.prepare(
            onReady = { count ->
                unsent.value = count
                confirming.value = true
            },
            // Synchro déjà reprise par `prepare` : rien à abandonner.
            onFailed = { prepared.value = false },
        )
    }

    private fun dismissSignOut() {
        if (confirming.compareAndSet(expect = true, update = false)) release()
    }

    /** Synchro arrêtée par `prepare` sans confirmation : elle reprend (fermeture, ou écran quitté). */
    internal fun release() {
        if (prepared.compareAndSet(expect = true, update = false)) signOut?.abandon()
    }

    override fun onCleared() {
        release()
    }

    /** `prepare` demandé, ni confirmé ni abandonné : la synchronisation est arrêtée. */
    private val prepared = MutableStateFlow(false)

    private fun confirmSignOut() {
        if (!confirming.compareAndSet(expect = true, update = false)) return
        // Confirmé : la déconnexion reprend la main sur la synchronisation.
        prepared.value = false
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

/** Dialogues de l'écran Compte : confirmation de la déconnexion, prénom. */
@Composable
internal fun AccountDialogs(
    state: AccountUiState,
    actions: AccountActions,
) {
    if (state.confirmingSignOut) SignOutConfirmation(state.unsentChanges, actions)
    if (state.editingName) NameDialog(state, actions)
}

@Composable
private fun SignOutConfirmation(
    unsentChanges: Int,
    actions: AccountActions,
) {
    AlertDialog(
        onDismissRequest = actions.onSignOutDismiss,
        title = { Text(stringResource(R.string.account_sign_out_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS)) {
                Text(stringResource(R.string.account_sign_out_body))
                if (unsentChanges > 0) Text(stringResource(R.string.account_sign_out_unsent))
            }
        },
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

/**
 * Par-dessus toute l'app : voile « Déconnexion… », puis le message d'échec. [blockedPurge] : purge en échec au moins
 * `AccountSession.PURGE_FAILURE_THRESHOLD` fois (#129) ; l'alerte propose alors de libérer de l'espace et « Nous
 * écrire ».
 */
@Composable
internal fun AccountSignOutOverlay(
    state: AccountSignOutState,
    onAcknowledge: () -> Unit,
    onRetry: () -> Unit = {},
    blockedPurge: PurgeFailure? = null,
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
            if (state.error == AccountSignOutError.Unknown) {
                SignOutRetry(onRetry, blockedPurge)
                return
            }
            AlertDialog(
                onDismissRequest = onAcknowledge,
                text = {
                    Text(
                        stringResource(R.string.account_sign_out_offline),
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

/**
 * Purge inachevée (drapeau posé) : ni Retour ni appui à côté, « Réessayer », sans redémarrer l'app. Titre et message
 * d'iOS. À partir du seuil ([blocked], #129) : libérer de l'espace ou réinstaller, et « Nous écrire », qui ouvre la
 * messagerie sans fermer l'alerte ; sans messagerie, l'adresse s'affiche, sélectionnable.
 */
@Composable
private fun SignOutRetry(
    onRetry: () -> Unit,
    blocked: PurgeFailure?,
) {
    val context = LocalContext.current
    var noMailApp by rememberSaveable { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = {},
        properties = DialogProperties(dismissOnBackPress = false, dismissOnClickOutside = false),
        title = { Text(stringResource(R.string.account_sign_out_failed_title)) },
        text = {
            // Message long aux grandes polices : il défile, les boutons restent visibles.
            Column(
                verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
                modifier = Modifier.verticalScroll(rememberScrollState()),
            ) {
                val body =
                    if (blocked != null) {
                        R.string.account_sign_out_failed_blocked_body
                    } else {
                        R.string.account_sign_out_failed_body
                    }
                Text(
                    stringResource(body),
                    modifier = Modifier.testTag(TAG_SIGN_OUT_MESSAGE).semantics { liveRegion = LiveRegionMode.Polite },
                )
                if (blocked != null && noMailApp) PurgeSupportAddress(TAG_SIGN_OUT_CONTACT_ADDRESS)
            }
        },
        confirmButton = {
            TextButton(
                onClick = onRetry,
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_SIGN_OUT_RETRY),
            ) { Text(stringResource(R.string.account_retry)) }
        },
        dismissButton =
            blocked?.let { failure ->
                {
                    TextButton(
                        onClick = { if (!openPurgeSupport(context, failure)) noMailApp = true },
                        modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_SIGN_OUT_CONTACT),
                    ) { Text(stringResource(R.string.purge_contact)) }
                }
            },
    )
}

internal const val TAG_SIGN_OUT_RETRY = "account-sign-out-retry"
internal const val TAG_SIGN_OUT_CONTACT = "account-sign-out-contact"
internal const val TAG_SIGN_OUT_CONTACT_ADDRESS = "account-sign-out-contact-address"
internal const val TAG_ACCOUNT_SIGN_OUT = "account-sign-out"
internal const val TAG_ACCOUNT_SIGN_OUT_CONFIRM = "account-sign-out-confirm"
internal const val TAG_ACCOUNT_NAME_FIELD = "account-name-field"
internal const val TAG_ACCOUNT_NAME_SAVE = "account-name-save"
internal const val TAG_SIGN_OUT_RUNNING = "account-sign-out-running"
internal const val TAG_SIGN_OUT_MESSAGE = "account-sign-out-message"
