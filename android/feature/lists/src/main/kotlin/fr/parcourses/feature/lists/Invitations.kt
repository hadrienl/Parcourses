package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import fr.parcourses.core.data.sharing.InvitationCardState
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
import fr.parcourses.core.network.dto.ReceivedInvitation
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.time.Instant
import kotlin.time.toJavaInstant

// Invitations reçues (#87 §9.5, maquette §5).

private fun ReceivedInvitation.content() = InvitationCardContent(inviterName, listName, role, expiresAt)

/** « 21 nov. » ; en entier (« 21 novembre ») quand le texte est agrandi. */
private fun expiryDate(
    at: Instant,
    long: Boolean,
): String =
    DateTimeFormatter
        .ofPattern(if (long) "d MMMM" else "d MMM", Locale.FRENCH)
        .format(at.toJavaInstant().atZone(ZoneId.systemDefault()))

/**
 * Carte d'une invitation : un seul élément de lecture (« Invitation. Hadrien vous invite à … »), puis « Refuser » et
 * « Accepter », côte à côte (« Accepter » à droite, sous le pouce) ou empilés en texte agrandi (« Accepter » d'abord).
 * Pendant l'acceptation, les boutons laissent place à « Ouverture de la liste… ».
 */
@Composable
fun InvitationCard(
    content: InvitationCardContent,
    label: String,
    accepting: Boolean,
    onAccept: () -> Unit,
    onDecline: (() -> Unit)?,
    modifier: Modifier = Modifier,
    acceptLabel: String = stringResource(R.string.inv_accept),
    footer: (@Composable () -> Unit)? = null,
) {
    val colors = Ticket.colors
    val large = isLargeText()
    val inviter = content.inviterName?.takeIf { it.isNotBlank() } ?: stringResource(R.string.inv_someone)
    val headline =
        content.listName?.let { stringResource(R.string.inv_card, inviter, it) }
            ?: stringResource(R.string.inv_card_other, inviter)
    val role = content.role?.let { roleLabel(it) }
    val meta =
        if (role != null && content.expiresAt != null) {
            stringResource(R.string.inv_meta, role, expiryDate(content.expiresAt, large))
        } else {
            role.orEmpty()
        }
    val spoken =
        if (role != null && content.expiresAt != null) {
            stringResource(R.string.inv_card_a11y, headline, role, expiryDate(content.expiresAt, long = true))
        } else {
            headline
        }
    Column(
        modifier
            .fillMaxWidth()
            .border(1.5.dp, colors.accent, RoundedCornerShape(TicketDimens.radius + 6.dp))
            .padding(TicketDimens.spaceM)
            .testTag(TAG_INVITATION_CARD),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
    ) {
        Column(Modifier.clearAndSetSemantics { contentDescription = spoken }) {
            CapsText(label, style = TicketType.aisle, color = colors.inkMuted)
            Row(Modifier.padding(top = TicketDimens.spaceXs), verticalAlignment = Alignment.Top) {
                MemberAvatar(SharingDecisions.memberInitial(content.inviterName), size = AvatarSize.member)
                Column(Modifier.padding(start = TicketDimens.spaceS)) {
                    Text(headline, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = colors.ink)
                    if (meta.isNotEmpty()) Text(meta, style = TicketType.meta, color = colors.inkMuted)
                }
            }
        }
        footer?.invoke()
        if (accepting) {
            Button(
                onClick = {},
                enabled = false,
                modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction),
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.size(TicketDimens.spaceXs))
                Text(
                    stringResource(R.string.inv_accepting),
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
            }
        } else {
            InvitationButtons(acceptLabel, onAccept, onDecline, stacked = large)
        }
    }
}

@Composable
private fun InvitationButtons(
    acceptLabel: String,
    onAccept: () -> Unit,
    onDecline: (() -> Unit)?,
    stacked: Boolean,
) {
    val colors = Ticket.colors
    val accept: @Composable (Modifier) -> Unit = { modifier ->
        Button(
            onClick = onAccept,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            modifier = modifier.heightIn(min = TicketDimens.primaryAction).testTag(TAG_INVITATION_ACCEPT),
        ) { Text(acceptLabel) }
    }
    val decline: @Composable (Modifier) -> Unit = { modifier ->
        if (onDecline != null) {
            FilledTonalButton(
                onClick = onDecline,
                colors =
                    ButtonDefaults.filledTonalButtonColors(
                        containerColor = colors.accentFill,
                        contentColor = colors.ink,
                    ),
                modifier = modifier.heightIn(min = TicketDimens.primaryAction).testTag(TAG_INVITATION_DECLINE),
            ) { Text(stringResource(R.string.inv_decline)) }
        }
    }
    if (stacked) {
        Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
            accept(Modifier.fillMaxWidth())
            decline(Modifier.fillMaxWidth())
        }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
            decline(Modifier.weight(1f))
            accept(Modifier.weight(1f))
        }
    }
}

/** Erreur d'une acceptation : sous la carte, annoncée. */
@Composable
internal fun InvitationErrorText(error: InvitationError) {
    val text = stringResource(if (error == InvitationError.Offline) R.string.inv_offline else R.string.inv_error)
    Row(verticalAlignment = Alignment.Top) {
        Icon(
            Icons.Outlined.Warning,
            contentDescription = null,
            tint = Ticket.colors.caution,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.ink,
            modifier = Modifier.padding(start = TicketDimens.spaceXs).semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/**
 * Invitations en tête de « Mes listes » : la carte s'il n'y en a qu'une, sinon la ligne « Invitations (2) » qui ouvre
 * leur liste. Refuser demande confirmation.
 */
@Composable
internal fun InvitationsEntry(
    state: InvitationsUiState,
    onAccept: (ReceivedInvitation) -> Unit,
    onDecline: (ReceivedInvitation) -> Unit,
    onOpenAll: () -> Unit,
) {
    val invitations = state.invitations
    if (invitations.isEmpty()) return
    if (invitations.size > 1) {
        InvitationsRow(invitations, onOpenAll)
        return
    }
    InvitationItem(
        invitations.first(),
        state,
        onAccept,
        onDecline,
        label = pluralStringResource(R.plurals.inv_entry, 1, 1),
    )
}

/** Une invitation, sa carte, son erreur et la confirmation de son refus. */
@Composable
private fun InvitationItem(
    invitation: ReceivedInvitation,
    state: InvitationsUiState,
    onAccept: (ReceivedInvitation) -> Unit,
    onDecline: (ReceivedInvitation) -> Unit,
    label: String,
) {
    var confirming by rememberSaveable(invitation.id.toString()) { mutableStateOf(false) }
    val id = invitation.id.toString()
    Column(
        Modifier.padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        InvitationCard(
            content = invitation.content(),
            label = label,
            accepting = state.accepting == id,
            onAccept = { onAccept(invitation) },
            onDecline = { confirming = true },
        )
        state.error?.takeIf { it.first == id }?.let { InvitationErrorText(it.second) }
    }
    if (confirming) {
        val inviter = invitation.inviterName?.takeIf { it.isNotBlank() } ?: stringResource(R.string.inv_someone)
        ConfirmDialog(
            title = stringResource(R.string.inv_decline_title),
            body = stringResource(R.string.inv_decline_body, inviter),
            confirm = stringResource(R.string.inv_decline),
            dismiss = stringResource(R.string.common_cancel),
            onConfirm = {
                confirming = false
                onDecline(invitation)
            },
            onDismiss = { confirming = false },
        )
    }
}

/** Ligne « Invitations (n) » de 56 dp, avec les prénoms de ceux qui invitent. */
@Composable
private fun InvitationsRow(
    invitations: List<ReceivedInvitation>,
    onOpen: () -> Unit,
) {
    val colors = Ticket.colors
    val title = pluralStringResource(R.plurals.inv_entry, invitations.size, invitations.size)
    val names =
        joinedNames(
            invitations
                .map {
                    it.inviterName?.takeIf(String::isNotBlank)
                        ?: stringResource(R.string.inv_someone)
                }.distinct(),
        )
    Row(
        Modifier
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
            .fillMaxWidth()
            .heightIn(min = TicketDimens.rowMin)
            .border(1.5.dp, colors.accent, RoundedCornerShape(TicketDimens.radius + 6.dp))
            .clickable(onClick = onOpen)
            .semantics(mergeDescendants = true) { role = Role.Button }
            .padding(horizontal = TicketDimens.spaceS)
            .testTag(TAG_INVITATIONS_ROW),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Email, contentDescription = null, tint = colors.ink)
        Column(Modifier.weight(1f).padding(horizontal = TicketDimens.spaceS, vertical = TicketDimens.spaceXs)) {
            Text(title, style = TicketType.item.copy(fontWeight = FontWeight.Bold), color = colors.ink)
            Text(names, style = MaterialTheme.typography.bodyMedium, color = colors.inkMuted)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.inkMuted)
    }
}

internal const val TAG_INVITATION_CARD = "invitation-card"
internal const val TAG_INVITATION_ACCEPT = "invitation-accept"
internal const val TAG_INVITATION_DECLINE = "invitation-decline"
internal const val TAG_INVITATIONS_ROW = "invitations-row"
internal const val TAG_INVITATION_CLOSE = "invitation-close"
internal const val TAG_INVITATION_OTHER = "invitation-other"
internal const val TAG_INVITATION_FINAL = "invitation-final"
internal const val TAG_INVITATION_ANON = "invitation-anon"
