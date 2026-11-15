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

// Feuille « Partager la liste », ses lignes et ses contrôles (#87, lot 87.6).

/** « Envoyer l'invitation », pleine largeur, 56 dp ; « Envoi… » pendant l'appel. */
@Composable
internal fun SendButton(
    sending: Boolean,
    onSend: () -> Unit,
) {
    val colors = Ticket.colors
    Button(
        onClick = onSend,
        enabled = !sending,
        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction).testTag(TAG_SHARE_SEND),
    ) {
        if (sending) {
            CircularProgressIndicator(Modifier.size(18.dp), color = colors.onAccent, strokeWidth = 2.dp)
            Spacer(Modifier.size(TicketDimens.spaceXs))
            Text(
                stringResource(R.string.share_sending),
                modifier =
                    Modifier.semantics {
                        liveRegion =
                            LiveRegionMode.Polite
                    },
            )
        } else {
            Text(stringResource(R.string.share_send))
        }
    }
}

/** « La personne invitée verra votre prénom… » */
@Composable
internal fun PrivacyNote() {
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            Icons.Outlined.Lock,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(16.dp),
        )
        Text(
            stringResource(R.string.share_note),
            style = MaterialTheme.typography.bodySmall,
            color = Ticket.colors.inkMuted,
            modifier = Modifier.padding(start = TicketDimens.spaceXs),
        )
    }
}

@Composable
internal fun SectionTitle(text: String) {
    CapsText(
        text,
        style = TicketType.aisle,
        color = Ticket.colors.inkMuted,
        modifier = Modifier.padding(top = TicketDimens.spaceS),
        heading = true,
    )
}

@Composable
internal fun LoadingRow() {
    Row(Modifier.fillMaxWidth().heightIn(min = TicketDimens.rowMin), verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(24.dp), color = Ticket.colors.accent, strokeWidth = 2.dp)
    }
}

/** L'e-mail n'est pas parti : le lien à donner soi-même, « Copier le lien » et « Partager… » (feuille du système). */
@Composable
internal fun MailFailCard(
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
                    Text(
                        stringResource(R.string.mailfail_body),
                        style = MaterialTheme.typography.bodyMedium,
                        color = Ticket.colors.ink,
                    )
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
internal fun MemberRow(
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
internal fun PendingRow(
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
internal fun expiryTexts(
    invitation: PendingInvitation,
    now: Instant,
): Pair<String, String> {
    val remaining = invitation.expiresAt - now
    val days = (remaining.inWholeHours + HOURS_PER_DAY - 1).div(HOURS_PER_DAY).toInt()
    val single: Int? =
        when {
            invitation.expired || invitation.expiresAt <= now -> R.string.pending_expired
            remaining.inWholeHours < HOURS_TODAY -> R.string.pending_expires_today
            else -> null
        }
    return single?.let { stringResource(it) to stringResource(it) }
        ?: (
            pluralStringResource(R.plurals.pending_expires_in, days, days) to
                pluralStringResource(R.plurals.pending_expires_in_a11y, days, days)
        )
}

internal const val HOURS_PER_DAY = 24L
internal const val HOURS_TODAY = 12L

/** Membre : la note, puis « Quitter la liste », séparé des membres par 24 dp. */
@Composable
internal fun MembersNote(state: ShareListUiState) {
    val owner = ownerName(state.sharing?.owner?.displayName)
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(16.dp),
        )
        Text(
            stringResource(R.string.members_note, owner),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.inkMuted,
            modifier = Modifier.padding(start = TicketDimens.spaceXs),
        )
    }
}

@Composable
internal fun LeaveButton(
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

/**
 * Accès « Peut modifier » / « Lecture seule » : boutons segmentés de 48 dp (un groupe radio pour TalkBack), « Peut
 * modifier » par défaut. En texte très agrandi, les deux options passent l'une sous l'autre.
 */
@Composable
internal fun RoleSelector(
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
                        .selectable(
                            selected = role == selected,
                            enabled = enabled,
                            role = Role.RadioButton,
                        ) { onRole(role) },
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
