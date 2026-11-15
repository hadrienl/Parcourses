package fr.parcourses.feature.lists

import android.content.ClipData
import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.error
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.sharing.InviteErrorKind
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.designsystem.AvatarSize
import fr.parcourses.core.designsystem.CapsText
import fr.parcourses.core.designsystem.MemberAvatar
import fr.parcourses.core.designsystem.NoticeCard
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.isLargeText
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.ListParticipant
import fr.parcourses.core.network.dto.PendingInvitation
import kotlin.time.Instant

/** Feuille « Partager la liste » branchée sur son modèle. [onLeft] : la personne a quitté la liste. */
@Composable
fun ShareListRoute(
    viewModel: ShareListViewModel,
    onClose: () -> Unit,
    onLeft: () -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(state.left) { if (state.left) onLeft() }
    val clipboard = LocalClipboard.current
    LaunchedEffect(state.clip) {
        state.clip?.let { link ->
            clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Parcourses", link)))
            viewModel.clipConsumed()
        }
    }
    // Toute frappe efface l'erreur affichée sous le champ.
    LaunchedEffect(viewModel) { snapshotFlow { viewModel.email.text.toString() }.collect { viewModel.emailEdited() } }
    ShareListScreen(
        state = state,
        email = viewModel.email,
        actions =
            ShareListActions(
                onClose = onClose,
                onSend = viewModel::send,
                onRole = viewModel::selectRole,
                onRetry = viewModel::retry,
                onResend = viewModel::resend,
                onCopy = viewModel::copyLink,
                onCopyMailFail = viewModel::copyMailFailLink,
                onRevoke = viewModel::revoke,
                onSetRole = viewModel::setRole,
                onRemove = viewModel::remove,
                onLeave = viewModel::leave,
                onMessageShown = viewModel::messageShown,
            ),
    )
}

/** Ce que la feuille demande à son modèle. */
class ShareListActions(
    val onClose: () -> Unit = {},
    val onSend: () -> Unit = {},
    val onRole: (ListRole) -> Unit = {},
    val onRetry: () -> Unit = {},
    val onResend: (PendingInvitation) -> Unit = {},
    val onCopy: (PendingInvitation) -> Unit = {},
    val onCopyMailFail: () -> Unit = {},
    val onRevoke: (PendingInvitation) -> Unit = {},
    val onSetRole: (ListParticipant, ListRole) -> Unit = { _, _ -> },
    val onRemove: (ListParticipant) -> Unit = {},
    val onLeave: () -> Unit = {},
    val onMessageShown: () -> Unit = {},
)

/**
 * Dialogue plein écran (Android, maquette §2) : barre ✕ + titre, retour prédictif de la navigation. Propriétaire :
 * e-mail, accès, envoi, membres et invitations en attente. Membre : la feuille « Membres », en lecture, avec « Quitter
 * la liste ». Tout défile ; le bouton d'envoi suit le contenu.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareListScreen(
    state: ShareListUiState,
    email: TextFieldState,
    actions: ShareListActions,
    modifier: Modifier = Modifier,
) {
    val colors = Ticket.colors
    val snackbar = remember { SnackbarHostState() }
    val messageText = state.message?.let { shareMessageText(it) }
    LaunchedEffect(state.message) {
        if (messageText != null) {
            snackbar.showSnackbar(messageText)
            actions.onMessageShown()
        }
    }
    var sheet by remember { mutableStateOf<ShareSheet?>(null) }
    val owner = state.load != ShareLoad.Loaded || state.isOwner
    Scaffold(
        modifier = modifier,
        containerColor = colors.paper,
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.paper),
                title = {
                    Text(
                        stringResource(if (owner) R.string.share_title else R.string.members_title),
                        style = TicketType.title,
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(onClick = actions.onClose, modifier = Modifier.testTag(TAG_SHARE_CLOSE)) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.sharing_close))
                    }
                },
            )
        },
    ) { padding ->
        when (state.load) {
            ShareLoad.Offline -> {
                ShareStatePage(stringResource(R.string.share_offline), offline = true, actions.onRetry, padding)
            }

            ShareLoad.Failed -> {
                ShareStatePage(stringResource(R.string.share_error), offline = false, actions.onRetry, padding)
            }

            else -> {
                ShareContent(state, email, actions, owner, padding) { sheet = it }
            }
        }
    }
    ShareSheets(state, sheet, actions) { sheet = it }
}

/** Membres, puis invitations en attente (propriétaire seulement), chacun suivi d'un séparateur. */
private fun LazyListScope.peopleItems(
    state: ShareListUiState,
    actions: ShareListActions,
    onSheet: (ShareSheet) -> Unit,
) {
    items(state.members, key = { "m-${it.userId}" }) { member ->
        MemberRow(
            member = member,
            manageable = state.isOwner && member.role != ListRole.Owner,
            busy = state.busyId == member.userId.toString(),
            onManage = { onSheet(ShareSheet.Member(member.userId.toString())) },
        )
        HorizontalDivider(color = Ticket.colors.paperEdge)
    }
    if (state.isOwner && state.invitations.isNotEmpty()) {
        item(key = "pending-title") { SectionTitle(stringResource(R.string.share_pending, state.invitations.size)) }
        items(state.invitations, key = { "i-${it.id}" }) { invitation ->
            PendingRow(
                invitation = invitation,
                busy = state.busyId == invitation.id.toString(),
                actions = actions,
                onMore = { onSheet(ShareSheet.Pending(invitation.id.toString())) },
                onRevoke = { onSheet(ShareSheet.ConfirmRevoke(invitation.id.toString())) },
            )
            HorizontalDivider(color = Ticket.colors.paperEdge)
        }
    }
}

@Composable
private fun ShareContent(
    state: ShareListUiState,
    email: TextFieldState,
    actions: ShareListActions,
    owner: Boolean,
    padding: PaddingValues,
    onSheet: (ShareSheet) -> Unit,
) {
    LazyColumn(
        Modifier.fillMaxSize().padding(padding).testTag(TAG_SHARE_LIST),
        contentPadding =
            PaddingValues(
                start = TicketDimens.spaceM,
                end = TicketDimens.spaceM,
                top = TicketDimens.spaceXs,
                bottom = TicketDimens.spaceL,
            ),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
    ) {
        item(key = "name") {
            Text(
                stringResource(R.string.share_list_name, state.listName),
                style = TicketType.meta,
                color = Ticket.colors.inkMuted,
            )
        }
        if (owner) {
            state.mailFailLink?.let { link -> item(key = "mailfail") { MailFailCard(link, actions.onCopyMailFail) } }
            item(key = "form") { InviteForm(state, email, actions) }
        }
        item(key = "members-title") {
            SectionTitle(stringResource(R.string.share_members, state.members.size.coerceAtLeast(1)))
        }
        if (state.load == ShareLoad.Loading) {
            item(key = "loading") { LoadingRow() }
        }
        peopleItems(state, actions, onSheet)
        if (state.isOwner && state.members.size <= 1 && state.invitations.isEmpty()) {
            item(key = "empty") {
                Text(
                    stringResource(R.string.share_empty),
                    style = MaterialTheme.typography.bodyMedium,
                    color = Ticket.colors.inkMuted,
                )
            }
        }
        if (state.load == ShareLoad.Loaded && !state.isOwner) {
            item(key = "members-note") { MembersNote(state) }
            item(key = "leave") { LeaveButton(state.busyId != null) { onSheet(ShareSheet.ConfirmLeave) } }
        }
    }
}

/** E-mail, accès, envoi et note de confidentialité. */
@Composable
private fun InviteForm(
    state: ShareListUiState,
    email: TextFieldState,
    actions: ShareListActions,
) {
    val colors = Ticket.colors
    val errorText = state.emailError?.let { inviteErrorText(it, state.refusedEmail) }
    Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS)) {
        OutlinedTextField(
            state = email,
            label = { Text(stringResource(R.string.share_email)) },
            placeholder = { Text(stringResource(R.string.share_email_placeholder)) },
            enabled = !state.isSending,
            isError = errorText != null,
            supportingText =
                if (errorText != null) {
                    { Text(errorText, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }) }
                } else {
                    null
                },
            lineLimits = TextFieldLineLimits.SingleLine,
            keyboardOptions =
                KeyboardOptions(
                    keyboardType = KeyboardType.Email,
                    capitalization = KeyboardCapitalization.None,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Send,
                ),
            onKeyboardAction = KeyboardActionHandler { actions.onSend() },
            modifier =
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = TicketDimens.primaryAction)
                    .semantics { if (errorText != null) error(errorText) }
                    .testTag(TAG_SHARE_EMAIL),
        )
        CapsText(stringResource(R.string.share_role), style = TicketType.aisle, color = colors.inkMuted)
        RoleSelector(state.role, enabled = !state.isSending, onRole = actions.onRole)
        Text(
            stringResource(if (state.role == ListRole.Viewer) R.string.role_viewer_help else R.string.role_editor_help),
            style = MaterialTheme.typography.bodyMedium,
            color = colors.inkMuted,
        )
        SendButton(state.isSending, actions.onSend)
        PrivacyNote()
    }
}

/** Hors ligne ou erreur du serveur : page entière, « Réessayer ». Rien n'est mis en file. */
@Composable
private fun ShareStatePage(
    text: String,
    offline: Boolean,
    onRetry: () -> Unit,
    padding: PaddingValues,
) {
    Column(
        Modifier
            .fillMaxSize()
            .padding(padding)
            .padding(32.dp)
            .testTag(TAG_SHARE_STATE),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            if (offline) Icons.Outlined.Info else Icons.Outlined.Warning,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(40.dp),
        )
        Text(
            text,
            style = MaterialTheme.typography.titleMedium,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
        Button(
            onClick = onRetry,
            colors =
                ButtonDefaults.buttonColors(
                    containerColor = Ticket.colors.accent,
                    contentColor = Ticket.colors.onAccent,
                ),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(TAG_SHARE_RETRY),
        ) { Text(stringResource(R.string.sharing_retry)) }
    }
}

@Composable
internal fun roleLabel(role: ListRole): String =
    stringResource(
        when (role) {
            ListRole.Owner -> R.string.role_owner
            ListRole.Editor -> R.string.role_editor
            ListRole.Viewer -> R.string.role_viewer
        },
    )

/** Message d'erreur sous le champ e-mail (vecteur `003`). */
@Composable
internal fun inviteErrorText(
    kind: InviteErrorKind,
    email: String?,
): String =
    when (kind) {
        InviteErrorKind.InvalidEmail -> stringResource(R.string.err_invalid)
        InviteErrorKind.SelfInvitation -> stringResource(R.string.err_self)
        InviteErrorKind.AlreadyMember -> stringResource(R.string.err_member, email.orEmpty())
        InviteErrorKind.ListFull -> stringResource(R.string.err_cap_list)
        InviteErrorKind.DailyLimit -> stringResource(R.string.err_cap_day)
        InviteErrorKind.PendingLimit -> stringResource(R.string.err_cap_live)
        InviteErrorKind.RecipientLimit -> stringResource(R.string.err_cap_to)
        InviteErrorKind.SignInRequired -> stringResource(R.string.err_sign_in)
        InviteErrorKind.Offline -> stringResource(R.string.share_offline)
        InviteErrorKind.NotAllowed, InviteErrorKind.Unknown -> stringResource(R.string.share_error)
    }

@Composable
private fun shareMessageText(message: ShareMessage): String =
    when (message) {
        is ShareMessage.Sent -> {
            stringResource(R.string.sent_ok, message.email)
        }

        ShareMessage.Resent -> {
            stringResource(R.string.sent_resent)
        }

        is ShareMessage.Copied -> {
            stringResource(if (message.fresh) R.string.copied_new else R.string.copied)
        }

        is ShareMessage.RoleChanged -> {
            val name = memberName(message.name)
            if (message.role == ListRole.Viewer) {
                stringResource(R.string.role_changed_viewer, name)
            } else {
                stringResource(R.string.role_changed_editor, name)
            }
        }

        ShareMessage.MemberOffline -> {
            stringResource(R.string.member_offline)
        }

        is ShareMessage.Failed -> {
            inviteErrorText(message.kind, null)
        }
    }

internal const val TAG_SHARE_CLOSE = "share-close"
internal const val TAG_SHARE_LIST = "share-list"
internal const val TAG_SHARE_EMAIL = "share-email"
internal const val TAG_SHARE_SEND = "share-send"
internal const val TAG_SHARE_MAIL_FAIL = "share-mail-fail"
internal const val TAG_SHARE_MEMBER = "share-member"
internal const val TAG_SHARE_PENDING = "share-pending"
internal const val TAG_SHARE_LEAVE = "share-leave"
internal const val TAG_SHARE_STATE = "share-state"
internal const val TAG_SHARE_RETRY = "share-retry"

internal const val TAG_SHARE_ROLE = "share-role"
