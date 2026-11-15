package fr.parcourses.app

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.autofill.ContentType
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.contentType
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import fr.parcourses.core.data.account.AccountLink
import fr.parcourses.core.data.account.AccountLinkError
import fr.parcourses.core.data.account.AccountLinkOutcome
import fr.parcourses.core.data.account.AccountLinkPhase
import fr.parcourses.core.data.account.AccountLinkState
import fr.parcourses.core.designsystem.MonoFamily
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketSheet
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

/** État de l'écran de connexion : la liaison, et le compte à rebours de « Renvoyer le code ». */
data class AccountLinkUiState(
    val link: AccountLinkState = AccountLinkState(),
    /** Secondes avant « Renvoyer le code » ; 0 : disponible. */
    val resendIn: Int = 0,
)

data class AccountLinkActions(
    val onRequestCode: (email: String, displayName: String?) -> Unit = { _, _ -> },
    val onVerify: (String) -> Unit = {},
    val onResend: () -> Unit = {},
    val onChangeEmail: () -> Unit = {},
    val onEdit: () -> Unit = {},
    val onRetryMerge: () -> Unit = {},
)

/** Porte une [AccountLink] le temps de l'écran : quitter l'écran avant le code n'a rien changé. */
class AccountLinkViewModel(
    private val link: AccountLink,
    private val now: () -> Instant = { Clock.System.now() },
) : ViewModel() {
    private val tick = MutableStateFlow(now())

    val state: StateFlow<AccountLinkUiState> =
        combine(link.state, tick) { current, at -> AccountLinkUiState(current, resendIn(current, at)) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, AccountLinkUiState(link.state.value))

    val actions =
        AccountLinkActions(
            onRequestCode = { email, name -> viewModelScope.launch { link.requestCode(email, name) } },
            onVerify = { code -> viewModelScope.launch { link.verify(code) } },
            onResend = { viewModelScope.launch { link.resendCode() } },
            onChangeEmail = link::changeEmail,
            onEdit = link::clearError,
            onRetryMerge = { viewModelScope.launch { link.retryMerge() } },
        )

    init {
        viewModelScope.launch { link.prepare() }
        viewModelScope.launch {
            while (isActive) {
                delay(1.seconds)
                tick.value = now()
            }
        }
    }

    private fun resendIn(
        state: AccountLinkState,
        at: Instant,
    ): Int {
        val sent = state.codeSentAt ?: return 0
        return (AccountLink.RESEND_DELAY - (at - sent)).inWholeSeconds.toInt().coerceAtLeast(0)
    }
}

/**
 * « Se connecter » (#87, maquette `design/sharing-v1.html`, écran 4) : adresse (et prénom pour un compte anonyme),
 * puis code à 6 chiffres, puis « Bon retour » après une connexion à un compte existant. [onClose] : ✕ ou fin.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountLinkScreen(
    state: AccountLinkUiState,
    actions: AccountLinkActions,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val phase = state.link.phase
    // La reprise des données ne s'interrompt pas : ni Retour ni ✕ pendant le rapprochement.
    // Vérification du code et reprise des données : ni Retour ni ✕ (elles iraient au bout quand même).
    val locked = state.link.busy || phase == AccountLinkPhase.Merging
    BackHandler(enabled = locked) {}
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.desk),
                title = {},
                navigationIcon = {
                    if (!locked) {
                        IconButton(onClick = onClose, modifier = Modifier.testTag(TAG_LINK_CLOSE)) {
                            Icon(Icons.Default.Close, contentDescription = stringResource(R.string.link_close))
                        }
                    }
                },
            )
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding).imePadding()) {
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(TicketDimens.spaceM),
                verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
            ) {
                when (phase) {
                    AccountLinkPhase.EnterEmail -> EmailStep(state.link, actions)
                    AccountLinkPhase.EnterCode -> CodeStep(state, actions)
                    AccountLinkPhase.Merging -> MergingStep(state.link, actions)
                    AccountLinkPhase.Done -> DoneStep(state.link, onClose)
                }
            }
        }
    }
}

@Composable
private fun Title(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.headlineSmall,
        color = Ticket.colors.ink,
        modifier = Modifier.semantics { heading() },
    )
}

@Composable
private fun Body(text: String) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = Ticket.colors.ink)
}

@Composable
private fun EmailStep(
    state: AccountLinkState,
    actions: AccountLinkActions,
) {
    var email by rememberSaveable { mutableStateOf(state.email) }
    var name by rememberSaveable { mutableStateOf("") }
    val emailValid = AccountLink.normalizedEmail(email) != null
    // Prénom facultatif (même règle qu'iOS) : vide, ou valable.
    val nameValid = !state.asksDisplayName || name.isBlank() || AccountLink.cleanedDisplayName(name) != null
    val canSend = emailValid && nameValid && !state.busy
    val send = {
        if (canSend) actions.onRequestCode(email, name.takeIf { state.asksDisplayName && it.isNotBlank() })
    }
    Title(stringResource(R.string.link_title))
    Body(stringResource(R.string.link_body))
    OutlinedTextField(
        value = email,
        onValueChange = {
            email = it
            actions.onEdit()
        },
        label = { Text(stringResource(R.string.link_email_label)) },
        placeholder = { Text(stringResource(R.string.link_email_placeholder)) },
        singleLine = true,
        isError = state.error == AccountLinkError.InvalidEmail,
        keyboardOptions =
            KeyboardOptions(
                keyboardType = KeyboardType.Email,
                capitalization = KeyboardCapitalization.None,
                autoCorrectEnabled = false,
                imeAction = if (state.asksDisplayName) ImeAction.Next else ImeAction.Send,
            ),
        keyboardActions = KeyboardActions(onSend = { send() }),
        modifier =
            Modifier
                .fillMaxWidth()
                .semantics { contentType = ContentType.EmailAddress }
                .testTag(TAG_LINK_EMAIL),
    )
    if (state.asksDisplayName) DisplayNameField(name, valid = nameValid, onChange = { name = it }, onSend = send)
    if (!state.asksDisplayName && state.unsentChanges > 0) {
        // Avertissement avant de lancer : un autre compte ne reçoit pas les données de celui-ci.
        Text(
            stringResource(R.string.link_unsent_warning),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.ink,
            modifier = Modifier.testTag(TAG_LINK_UNSENT),
        )
    }
    // Compte e-mail qui se reconnecte (pas de prénom demandé) : une adresse bien formée refusée n'a pas de compte.
    val noAccount = !state.asksDisplayName && emailValid
    state.error?.let { ErrorMessage(requestErrorText(it, noAccount)) }
    Spacer(Modifier.heightIn(min = TicketDimens.spaceXs))
    PrimaryButton(
        text = stringResource(if (state.busy) R.string.link_sending else R.string.link_cta),
        enabled = canSend,
        busy = state.busy,
        onClick = send,
        tag = TAG_LINK_SEND,
    )
}

@Composable
private fun CodeStep(
    state: AccountLinkUiState,
    actions: AccountLinkActions,
) {
    val link = state.link
    var code by rememberSaveable { mutableStateOf("") }
    // Code refusé : le champ se vide et garde le focus (maquette).
    LaunchedEffect(link.error) { if (link.error != null) code = "" }
    Title(stringResource(R.string.code_title))
    Body(stringResource(R.string.code_sent_to, link.email))
    CodeField(
        value = code,
        error = link.error != null,
        enabled = !link.busy,
        onValueChange = { typed ->
            val digits = typed.filter(Char::isDigit).take(AccountLink.CODE_LENGTH)
            code = digits
            if (link.error != null) actions.onEdit()
            // Validation automatique au 6ᵉ chiffre, collage compris.
            if (digits.length == AccountLink.CODE_LENGTH) actions.onVerify(digits)
        },
    )
    link.error?.let { ErrorMessage(codeErrorText(it)) }
    if (link.busy) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
            modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            CircularProgressIndicator(modifier = Modifier.size(size = 20.dp), color = Ticket.colors.ink)
            Text(stringResource(R.string.code_verifying), color = Ticket.colors.ink)
        }
    }
    val ready = state.resendIn == 0
    val readyText = stringResource(R.string.code_ready)
    OutlinedButton(
        onClick = {
            code = ""
            actions.onResend()
        },
        enabled = ready && !link.busy,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = TicketDimens.touchMin)
                .semantics { if (ready) liveRegion = LiveRegionMode.Polite }
                .testTag(TAG_CODE_RESEND),
    ) {
        Text(
            if (ready) {
                stringResource(
                    R.string.code_resend,
                )
            } else {
                stringResource(R.string.code_resend_in, state.resendIn)
            },
            modifier = Modifier.semantics { if (ready) stateDescription = readyText },
        )
    }
    TextButton(
        onClick = actions.onChangeEmail,
        enabled = !link.busy,
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin).testTag(TAG_CODE_CHANGE),
    ) { Text(stringResource(R.string.code_change), color = Ticket.colors.ink) }
}

@Composable
private fun MergingStep(
    state: AccountLinkState,
    actions: AccountLinkActions,
) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 96.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceM),
    ) {
        // Purge d'un changement de compte inachevée : message et « Réessayer », la synchronisation reste arrêtée.
        val error = state.error
        if (error != null && !state.busy) {
            ErrorMessage(requestErrorText(error))
            PrimaryButton(
                text = stringResource(R.string.account_retry),
                enabled = true,
                busy = false,
                onClick = actions.onRetryMerge,
                tag = TAG_LINK_RETRY,
            )
            return@Column
        }
        CircularProgressIndicator(color = Ticket.colors.ink)
        Text(
            stringResource(R.string.link_merging),
            style = MaterialTheme.typography.titleMedium,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag(TAG_LINK_MERGING),
        )
    }
}

@Composable
private fun DoneStep(
    state: AccountLinkState,
    onClose: () -> Unit,
) {
    val colors = Ticket.colors
    Column(
        modifier = Modifier.fillMaxWidth().padding(top = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceM),
    ) {
        Box(
            contentAlignment = Alignment.Center,
            modifier = Modifier.size(size = 64.dp).border(2.dp, colors.accent, CircleShape),
        ) { Icon(Icons.Default.Check, contentDescription = null, tint = colors.accent) }
        val signedIn = state.outcome as? AccountLinkOutcome.SignedIn
        if (signedIn != null) {
            val title =
                signedIn.displayName?.let { stringResource(R.string.link_welcome_title, it) }
                    ?: stringResource(R.string.link_welcome_title_plain)
            Text(
                title,
                style = MaterialTheme.typography.headlineSmall,
                color = colors.ink,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() }.testTag(TAG_LINK_DONE_TITLE),
            )
            if (signedIn.addedLists > 0) {
                Text(
                    pluralStringResource(R.plurals.link_welcome_body, signedIn.addedLists, signedIn.addedLists),
                    style = MaterialTheme.typography.bodyMedium,
                    color = colors.inkMuted,
                    textAlign = TextAlign.Center,
                )
            }
        } else {
            Text(
                stringResource(R.string.link_linked),
                style = MaterialTheme.typography.titleMedium,
                color = colors.ink,
                textAlign = TextAlign.Center,
                modifier = Modifier.semantics { heading() }.testTag(TAG_LINK_DONE_TITLE),
            )
        }
        PrimaryButton(
            text = stringResource(if (signedIn != null) R.string.link_welcome_cta else R.string.link_done_cta),
            enabled = true,
            busy = false,
            onClick = onClose,
            tag = TAG_LINK_DONE,
        )
    }
}

internal const val TAG_LINK_CLOSE = "link-close"
internal const val TAG_LINK_UNSENT = "link-unsent"
internal const val TAG_LINK_RETRY = "link-retry"
internal const val TAG_LINK_EMAIL = "link-email"
internal const val TAG_LINK_NAME = "link-name"
internal const val TAG_LINK_SEND = "link-send"
internal const val TAG_LINK_ERROR = "link-error"
internal const val TAG_CODE_FIELD = "code-field"
internal const val TAG_CODE_RESEND = "code-resend"
internal const val TAG_CODE_CHANGE = "code-change"
internal const val TAG_LINK_MERGING = "link-merging"
internal const val TAG_LINK_DONE_TITLE = "link-done-title"
internal const val TAG_LINK_DONE = "link-done"
