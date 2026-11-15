package fr.parcourses.feature.lists

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ExitToApp
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.designsystem.AvatarSize
import fr.parcourses.core.designsystem.MemberAvatar
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.isLargeText
import fr.parcourses.core.model.ListRole
import fr.parcourses.core.network.dto.ListParticipant
import fr.parcourses.core.network.dto.PendingInvitation
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.time.Instant
import kotlin.time.toJavaInstant

/** Feuilles et confirmations de « Partager la liste » (maquette §2 et §3) : bottom sheet modale, AlertDialog M3. */
@Composable
internal fun ShareSheets(
    state: ShareListUiState,
    sheet: ShareSheet?,
    actions: ShareListActions,
    onSheet: (ShareSheet?) -> Unit,
) {
    val close = { onSheet(null) }
    when (sheet) {
        is ShareSheet.Member -> {
            state.members.firstOrNull { it.userId.toString() == sheet.userId }?.let { member ->
                MemberSheet(
                    member = member,
                    onRole = { role ->
                        close()
                        actions.onSetRole(member, role)
                    },
                    onRemove = { onSheet(ShareSheet.ConfirmRemove(sheet.userId)) },
                    onDismiss = close,
                )
            }
        }

        is ShareSheet.Pending -> {
            state.invitations.firstOrNull { it.id.toString() == sheet.id }?.let { invitation ->
                PendingSheet(
                    invitation = invitation,
                    onResend = {
                        close()
                        actions.onResend(invitation)
                    },
                    onCopy = {
                        close()
                        actions.onCopy(invitation)
                    },
                    onRevoke = { onSheet(ShareSheet.ConfirmRevoke(sheet.id)) },
                    onDismiss = close,
                )
            }
        }

        is ShareSheet.ConfirmRemove -> {
            state.members.firstOrNull { it.userId.toString() == sheet.userId }?.let { member ->
                val name = memberName(member.displayName)
                ConfirmDialog(
                    title = stringResource(R.string.remove_title, name),
                    body = stringResource(R.string.remove_body, name, state.listName),
                    confirm = stringResource(R.string.remove_btn),
                    dismiss = stringResource(R.string.common_cancel),
                    onConfirm = {
                        close()
                        actions.onRemove(member)
                    },
                    onDismiss = close,
                )
            }
        }

        is ShareSheet.ConfirmRevoke -> {
            state.invitations.firstOrNull { it.id.toString() == sheet.id }?.let { invitation ->
                ConfirmDialog(
                    title = stringResource(R.string.revoke_title),
                    body = stringResource(R.string.revoke_body, invitation.email),
                    confirm = stringResource(R.string.pending_revoke),
                    dismiss = stringResource(R.string.revoke_keep),
                    onConfirm = {
                        close()
                        actions.onRevoke(invitation)
                    },
                    onDismiss = close,
                )
            }
        }

        ShareSheet.ConfirmLeave -> {
            val owner = ownerName(state.sharing?.owner?.displayName)
            ConfirmDialog(
                title = stringResource(R.string.leave_title, state.listName),
                body = stringResource(R.string.leave_body, owner),
                confirm = stringResource(R.string.leave_btn),
                dismiss = stringResource(R.string.common_cancel),
                onConfirm = {
                    close()
                    actions.onLeave()
                },
                onDismiss = close,
            )
        }

        null -> {
            Unit
        }
    }
}

/** Feuille ouverte au-dessus de « Partager » : un membre, une invitation, une confirmation. */
internal sealed interface ShareSheet {
    data class Member(
        val userId: String,
    ) : ShareSheet

    data class Pending(
        val id: String,
    ) : ShareSheet

    data class ConfirmRemove(
        val userId: String,
    ) : ShareSheet

    data class ConfirmRevoke(
        val id: String,
    ) : ShareSheet

    data object ConfirmLeave : ShareSheet
}

/**
 * Gérer un membre (propriétaire) : son prénom, « Membre depuis le … », l'accès en boutons radio, puis « Retirer de la
 * liste » séparé et rouge. Options de 56 dp ; en texte très agrandi, la feuille s'ouvre en entier.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MemberSheet(
    member: ListParticipant,
    onRole: (ListRole) -> Unit,
    onRemove: () -> Unit,
    onDismiss: () -> Unit,
) {
    val name = memberName(member.displayName)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = isLargeText()),
        containerColor = Ticket.colors.paper,
        modifier = Modifier.testTag(TAG_MEMBER_SHEET),
    ) {
        Column(Modifier.padding(horizontal = TicketDimens.spaceM).padding(bottom = TicketDimens.spaceL)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.semantics(mergeDescendants = true) { heading() }) {
                MemberAvatar(SharingDecisions.memberInitial(member.displayName), size = AvatarSize.member)
                Column(Modifier.padding(start = TicketDimens.spaceS)) {
                    Text(name, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = Ticket.colors.ink)
                    member.joinedAt?.let {
                        Text(
                            stringResource(R.string.member_since, longDate(it)),
                            style = MaterialTheme.typography.bodyMedium,
                            color = Ticket.colors.inkMuted,
                        )
                    }
                }
            }
            Column(Modifier.selectableGroup().padding(vertical = TicketDimens.spaceXs)) {
                RoleOption(ListRole.Editor, R.string.role_editor_help, member.role == ListRole.Editor) { onRole(ListRole.Editor) }
                RoleOption(ListRole.Viewer, R.string.role_viewer_help, member.role == ListRole.Viewer) { onRole(ListRole.Viewer) }
            }
            SheetAction(
                Icons.AutoMirrored.Filled.ExitToApp,
                stringResource(R.string.member_remove),
                Ticket.colors.destructive,
                onRemove,
                Modifier.testTag(TAG_MEMBER_REMOVE),
            )
        }
    }
}

@Composable
private fun RoleOption(
    role: ListRole,
    help: Int,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = TicketDimens.primaryAction)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onSelect)
            .testTag("$TAG_MEMBER_ROLE-${role.wireName}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Column(Modifier.padding(start = TicketDimens.spaceS, top = 6.dp, bottom = 6.dp)) {
            Text(roleLabel(role), style = MaterialTheme.typography.bodyLarge, color = Ticket.colors.ink)
            Text(stringResource(help), style = MaterialTheme.typography.bodyMedium, color = Ticket.colors.inkMuted)
        }
    }
}

/** Actions d'une invitation en attente : Renvoyer, Copier le lien, Annuler l'invitation (confirmée). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PendingSheet(
    invitation: PendingInvitation,
    onResend: () -> Unit,
    onCopy: () -> Unit,
    onRevoke: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = isLargeText()),
        containerColor = Ticket.colors.paper,
        modifier = Modifier.testTag(TAG_PENDING_SHEET),
    ) {
        Column(
            Modifier.padding(horizontal = TicketDimens.spaceM).padding(bottom = TicketDimens.spaceL),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "${invitation.email} · ${roleLabel(invitation.role)}",
                style = MaterialTheme.typography.bodyMedium,
                color = Ticket.colors.inkMuted,
                modifier = Modifier.semantics { heading() },
            )
            SheetAction(Icons.Default.Refresh, stringResource(R.string.pending_resend), Ticket.colors.ink, onResend)
            SheetAction(Icons.Default.Share, stringResource(R.string.pending_copy), Ticket.colors.ink, onCopy)
            SheetAction(
                Icons.Default.Close,
                stringResource(R.string.pending_revoke),
                Ticket.colors.destructive,
                onRevoke,
                Modifier.testTag(TAG_PENDING_REVOKE),
            )
        }
    }
}

@Composable
private fun SheetAction(
    icon: ImageVector,
    label: String,
    color: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    TextButton(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction),
    ) {
        Icon(icon, contentDescription = null, tint = color)
        Text(
            label,
            color = color,
            style = MaterialTheme.typography.bodyLarge,
            modifier = Modifier.weight(1f).padding(start = TicketDimens.spaceS),
        )
    }
}

/** Confirmation destructive : « Annuler » (ou « Garder ») est le bouton par défaut, l'action en rouge. */
@Composable
internal fun ConfirmDialog(
    title: String,
    body: String,
    confirm: String,
    dismiss: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Ticket.colors.paper,
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_CONFIRM_SHARING),
            ) { Text(confirm, color = Ticket.colors.destructive) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
                Text(dismiss, color = Ticket.colors.accent)
            }
        },
    )
}

/** « 12 novembre ». */
internal fun longDate(at: Instant): String =
    DateTimeFormatter
        .ofPattern("d MMMM", Locale.FRENCH)
        .format(at.toJavaInstant().atZone(ZoneId.systemDefault()))

internal const val TAG_MEMBER_SHEET = "member-sheet"
internal const val TAG_MEMBER_ROLE = "member-role"
internal const val TAG_MEMBER_REMOVE = "member-remove"
internal const val TAG_PENDING_SHEET = "pending-sheet"
internal const val TAG_PENDING_REVOKE = "pending-revoke"
internal const val TAG_CONFIRM_SHARING = "sharing-confirm"
