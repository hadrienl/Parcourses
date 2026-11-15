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
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Scaffold
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
        contentPadding = PaddingValues(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
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
        item(key = "bottom") { Spacer(Modifier.height(TicketDimens.spaceL)) }
    }
}

@Composable
private fun SectionTitle(text: String) {
    CapsText(
        text,
        style = TicketType.aisle,
        color = Ticket.colors.inkMuted,
        modifier = Modifier.padding(top = TicketDimens.spaceS),
        heading = true,
    )
}

@Composable
private fun LoadingRow() {
    Row(Modifier.fillMaxWidth().heightIn(min = TicketDimens.rowMin), verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(24.dp), color = Ticket.colors.accent, strokeWidth = 2.dp)
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
        Button(
            onClick = actions.onSend,
            enabled = !state.isSending,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(TAG_SHARE_SEND),
        ) {
            if (state.isSending) {
                CircularProgressIndicator(Modifier.size(18.dp), color = colors.onAccent, strokeWidth = 2.dp)
                Spacer(Modifier.size(TicketDimens.spaceXs))
                Text(stringResource(R.string.share_sending), modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            } else {
                Text(stringResource(R.string.share_send))
            }
        }
        Row(verticalAlignment = Alignment.Top) {
            Icon(Icons.Outlined.Lock, contentDescription = null, tint = colors.inkMuted, modifier = Modifier.size(16.dp))
            Text(
                stringResource(R.string.share_note),
                style = MaterialTheme.typography.bodySmall,
                color = colors.inkMuted,
                modifier = Modifier.padding(start = TicketDimens.spaceXs),
            )
        }
    }
}

/** L'e-mail n'est pas parti : le lien à donner soi-même, « Copier le lien » et « Partager… » (feuille du système). */
@Composable
private fun MailFailCard(
    link: String,
    onCopy: () -> Unit,
) {
    val context = LocalContext.current
    val chooserTitle = stringResource(R.string.mailfail_share)
    NoticeCard(Modifier.fillMaxWidth().testTag(TAG_SHARE_MAIL_FAIL)) {
        Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(Icons.Outlined.Warning, contentDescription = null, tint = Ticket.colors.caution)
                Column(Modifier.padding(start = TicketDimens.spaceXs)) {
                    Text(
                        stringResource(R.string.mailfail_title),
                        style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                        color = Ticket.colors.ink,
                        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                    )
                    Text(stringResource(R.string.mailfail_body), style = MaterialTheme.typography.bodyMedium, color = Ticket.colors.ink)
                }
            }
            FilledTonalButton(
                onClick = onCopy,
                modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin),
            ) { Text(stringResource(R.string.pending_copy)) }
            FilledTonalButton(
                onClick = {
                    val send = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, link)
                    context.startActivity(Intent.createChooser(send, chooserTitle))
                },
                modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin),
            ) {
                Icon(Icons.Default.Share, contentDescription = null)
                Spacer(Modifier.size(TicketDimens.spaceXs))
                Text(chooserTitle)
            }
        }
    }
}

/** Personne de la liste : avatar, prénom (« vous »), accès ; ⋮ pour la gérer (propriétaire). Ligne de 56 dp. */
@Composable
private fun MemberRow(
    member: ListParticipant,
    manageable: Boolean,
    busy: Boolean,
    onManage: () -> Unit,
) {
    val colors = Ticket.colors
    val name = memberName(member.displayName)
    val shown = if (member.isMe) stringResource(R.string.member_name_you, name) else name
    val roleText = roleLabel(member.role)
    val label =
        if (manageable) {
            stringResource(R.string.member_manage_a11y, shown, roleText.lowercase())
        } else {
            stringResource(R.string.member_a11y, shown, roleText.lowercase())
        }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = TicketDimens.rowMin)
            .then(if (manageable) Modifier.clickable(onClick = onManage) else Modifier)
            .clearAndSetSemantics {
                contentDescription = label
                if (manageable) role = Role.Button
            }.testTag("$TAG_SHARE_MEMBER-${member.userId}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MemberAvatar(SharingDecisions.memberInitial(member.displayName), size = AvatarSize.member)
        Column(Modifier.weight(1f).padding(horizontal = TicketDimens.spaceS, vertical = TicketDimens.spaceXs)) {
            Text(shown, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = colors.ink)
            Text(roleText, style = MaterialTheme.typography.bodyMedium, color = colors.inkMuted)
        }
        when {
            busy -> CircularProgressIndicator(Modifier.size(24.dp), color = colors.accent, strokeWidth = 2.dp)
            manageable -> IconButton(onClick = onManage) { Icon(Icons.Default.MoreVert, contentDescription = null) }
        }
    }
}

/** Invitation en attente : adresse, accès, échéance ; « Renvoyer » si expirée, sinon ⋮. Actions aussi pour TalkBack. */
@Composable
private fun PendingRow(
    invitation: PendingInvitation,
    busy: Boolean,
    actions: ShareListActions,
    onMore: () -> Unit,
    onRevoke: () -> Unit,
) {
    val colors = Ticket.colors
    val now = rememberNow()
    val roleText = roleLabel(invitation.role)
    val (expiry, spokenExpiry) = expiryTexts(invitation, now)
    val label = stringResource(R.string.pending_row_a11y, invitation.email, roleText.lowercase(), spokenExpiry)
    val resend = stringResource(R.string.pending_resend)
    val copy = stringResource(R.string.pending_copy)
    val revoke = stringResource(R.string.pending_revoke)
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = TicketDimens.rowMin)
            .semantics(mergeDescendants = true) {
                contentDescription = label
                customActions =
                    listOf(
                        CustomAccessibilityAction(resend) { actions.onResend(invitation).let { true } },
                        CustomAccessibilityAction(copy) { actions.onCopy(invitation).let { true } },
                        CustomAccessibilityAction(revoke) { onRevoke().let { true } },
                    )
            }.testTag("$TAG_SHARE_PENDING-${invitation.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(vertical = TicketDimens.spaceXs).clearAndSetSemantics { }) {
            Text(invitation.email, style = MaterialTheme.typography.bodyLarge, color = colors.ink)
            Text(
                "$roleText · $expiry",
                style = MaterialTheme.typography.bodyMedium,
                color = if (invitation.expired) colors.caution else colors.inkMuted,
            )
        }
        when {
            busy -> {
                CircularProgressIndicator(Modifier.size(24.dp), color = colors.accent, strokeWidth = 2.dp)
            }

            invitation.expired -> {
                FilledTonalButton(
                    onClick = { actions.onResend(invitation) },
                    modifier = Modifier.heightIn(min = TicketDimens.touchMin).clearAndSetSemantics { },
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                    Text(resend, modifier = Modifier.padding(start = 4.dp))
                }
            }

            else -> {
                IconButton(onClick = onMore, modifier = Modifier.clearAndSetSemantics { }) {
                    Icon(Icons.Default.MoreVert, contentDescription = null)
                }
            }
        }
    }
}

/** « expire dans 7 j » / « Expirée », et sa forme lue. */
@Composable
private fun expiryTexts(
    invitation: PendingInvitation,
    now: Instant,
): Pair<String, String> {
    if (invitation.expired || invitation.expiresAt <= now) {
        val expired = stringResource(R.string.pending_expired)
        return expired to expired
    }
    val remaining = invitation.expiresAt - now
    val days = (remaining.inWholeHours + HOURS_PER_DAY - 1).div(HOURS_PER_DAY).toInt()
    if (remaining.inWholeHours < HOURS_TODAY) {
        val today = stringResource(R.string.pending_expires_today)
        return today to today
    }
    return pluralStringResource(R.plurals.pending_expires_in, days, days) to
        pluralStringResource(R.plurals.pending_expires_in_a11y, days, days)
}

private const val HOURS_PER_DAY = 24L
private const val HOURS_TODAY = 12L

/** Membre : la note, puis « Quitter la liste », séparé des membres par 24 dp. */
@Composable
private fun MembersNote(state: ShareListUiState) {
    val owner = ownerName(state.sharing?.owner?.displayName)
    Row(verticalAlignment = Alignment.Top) {
        Icon(Icons.Outlined.Info, contentDescription = null, tint = Ticket.colors.inkMuted, modifier = Modifier.size(16.dp))
        Text(
            stringResource(R.string.members_note, owner),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            modifier = Modifier.padding(start = TicketDimens.spaceXs),
        )
    }
}

@Composable
private fun LeaveButton(
    busy: Boolean,
    onClick: () -> Unit,
) {
    TextButton(
        onClick = onClick,
        enabled = !busy,
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(top = TicketDimens.spaceL)
                .heightIn(min = TicketDimens.touchMin)
                .testTag(TAG_SHARE_LEAVE),
    ) {
        Icon(Icons.AutoMirrored.Filled.ExitToApp, contentDescription = null, tint = Ticket.colors.destructive)
        Text(
            stringResource(R.string.lists_leave),
            color = Ticket.colors.destructive,
            modifier = Modifier.padding(start = TicketDimens.spaceXs),
        )
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
        Modifier.fillMaxSize().padding(padding).padding(32.dp).testTag(TAG_SHARE_STATE),
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
            colors = ButtonDefaults.buttonColors(containerColor = Ticket.colors.accent, contentColor = Ticket.colors.onAccent),
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
        is ShareMessage.Sent -> stringResource(R.string.sent_ok, message.email)
        ShareMessage.Resent -> stringResource(R.string.sent_resent)
        is ShareMessage.Copied -> stringResource(if (message.fresh) R.string.copied_new else R.string.copied)
        is ShareMessage.RoleChanged -> {
            val name = memberName(message.name)
            if (message.role == ListRole.Viewer) {
                stringResource(R.string.role_changed_viewer, name)
            } else {
                stringResource(R.string.role_changed_editor, name)
            }
        }

        ShareMessage.MemberOffline -> stringResource(R.string.member_offline)
        is ShareMessage.Failed -> inviteErrorText(message.kind, null)
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

/**
 * Accès « Peut modifier » / « Lecture seule » : boutons segmentés de 48 dp (un groupe radio pour TalkBack), « Peut
 * modifier » par défaut. En texte très agrandi, les deux options passent l'une sous l'autre.
 */
@Composable
private fun RoleSelector(
    selected: ListRole,
    enabled: Boolean,
    onRole: (ListRole) -> Unit,
) {
    val options = listOf(ListRole.Editor, ListRole.Viewer)
    if (isLargeText()) {
        Column(Modifier.selectableGroup().testTag(TAG_SHARE_ROLE)) {
            options.forEach { role ->
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = TicketDimens.touchMin)
                        .selectable(selected = role == selected, enabled = enabled, role = Role.RadioButton) { onRole(role) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = role == selected, onClick = null, enabled = enabled)
                    Text(roleLabel(role), modifier = Modifier.padding(start = TicketDimens.spaceS))
                }
            }
        }
        return
    }
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().selectableGroup().testTag(TAG_SHARE_ROLE)) {
        options.forEachIndexed { index, role ->
            SegmentedButton(
                selected = role == selected,
                onClick = { onRole(role) },
                enabled = enabled,
                shape = SegmentedButtonDefaults.itemShape(index, options.size),
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag("$TAG_SHARE_ROLE-${role.wireName}"),
            ) { Text(roleLabel(role)) }
        }
    }
}

internal const val TAG_SHARE_ROLE = "share-role"
