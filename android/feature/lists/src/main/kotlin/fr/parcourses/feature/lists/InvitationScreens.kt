package fr.parcourses.feature.lists

import android.widget.Toast
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
import androidx.compose.ui.platform.LocalContext
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
import fr.parcourses.core.data.sharing.AcceptOutcome
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

// Invitation ouverte par son lien (#87 §1.3, maquette §5).

/**
 * Invitation ouverte par son lien (§5) : la carte, ou l'avertissement « autre adresse », ou l'état final (expirée,
 * déjà utilisée, plus valable). Écran plein, fermé par ✕ (la maquette Android montre une bottom sheet ; ici l'écran
 * entier, ouvert par la navigation au-dessus de « Mes listes »).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InvitationLinkScreen(
    state: InvitationLinkUiState,
    onAccept: () -> Unit,
    onRetry: () -> Unit,
    onSwitchAccount: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        containerColor = Ticket.colors.paper,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Ticket.colors.paper),
                title = { Text(stringResource(R.string.inv_sheet), modifier = Modifier.semantics { heading() }) },
                navigationIcon = {
                    IconButton(onClick = onClose, modifier = Modifier.testTag(TAG_INVITATION_CLOSE)) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.sharing_close))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(TicketDimens.spaceM),
            verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
        ) {
            InvitationLinkBody(state, onAccept, onRetry, onSwitchAccount, onClose)
        }
    }
}

@Composable
private fun InvitationLinkBody(
    state: InvitationLinkUiState,
    onAccept: () -> Unit,
    onRetry: () -> Unit,
    onSwitchAccount: () -> Unit,
    onClose: () -> Unit,
) {
    when {
        state.loading -> {
            CircularProgressIndicator(Modifier.size(32.dp), color = Ticket.colors.accent)
        }

        state.error != null && state.preview == null -> {
            UnreachableInvitation(state.error, onRetry)
        }

        state.card == InvitationCardState.Acceptable || state.card == InvitationCardState.AlreadyMember -> {
            AcceptableInvitation(state, onAccept)
        }

        state.card == InvitationCardState.OtherAddress -> {
            OtherAddressInvitation(state, onAccept, onSwitchAccount)
        }

        else -> {
            ClosedInvitation(state, onClose)
        }
    }
}

/** Aperçu impossible (hors ligne, erreur) : « Réessayer ». */
@Composable
private fun UnreachableInvitation(
    error: InvitationError,
    onRetry: () -> Unit,
) {
    FinalState(stringResource(if (error == InvitationError.Offline) R.string.inv_offline else R.string.inv_error))
    Button(
        onClick = onRetry,
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction),
    ) { Text(stringResource(R.string.sharing_retry)) }
}

/** Invitation pour mon adresse (ou déjà membre : l'acceptation, idempotente, est en cours). */
@Composable
private fun AcceptableInvitation(
    state: InvitationLinkUiState,
    onAccept: () -> Unit,
) {
    val preview = state.preview
    InvitationCard(
        content = InvitationCardContent(preview?.inviterName, preview?.listName, preview?.role, preview?.expiresAt),
        label = stringResource(R.string.inv_sheet),
        accepting = state.accepting || state.card == InvitationCardState.AlreadyMember,
        onAccept = onAccept,
        onDecline = null,
    )
    state.error?.let { InvitationErrorText(it) }
}

/** Invitation pour une autre adresse (Q4) : avertissement, carte sans nom de liste, « Changer de compte ». */
@Composable
private fun OtherAddressInvitation(
    state: InvitationLinkUiState,
    onAccept: () -> Unit,
    onSwitchAccount: () -> Unit,
) {
    val preview = state.preview
    OtherAddressWarning(state, inviterOf(state))
    InvitationCard(
        content = InvitationCardContent(preview?.inviterName, null, preview?.role, preview?.expiresAt),
        label = stringResource(R.string.inv_sheet),
        accepting = state.accepting,
        onAccept = onAccept,
        onDecline = null,
        acceptLabel = stringResource(R.string.inv_other_accept),
    )
    state.error?.let { InvitationErrorText(it) }
    TextButton(
        onClick = onSwitchAccount,
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin),
    ) { Text(stringResource(R.string.inv_other_switch), color = Ticket.colors.accent) }
}

/** Expirée, déjà utilisée, plus valable ou trop d'essais : le texte, puis « Fermer ». */
@Composable
private fun ClosedInvitation(
    state: InvitationLinkUiState,
    onClose: () -> Unit,
) {
    val text =
        when (state.card) {
            InvitationCardState.Expired -> stringResource(R.string.inv_expired, inviterOf(state))
            InvitationCardState.Used -> stringResource(R.string.inv_used)
            InvitationCardState.RateLimited -> stringResource(R.string.inv_rate_limited)
            else -> stringResource(R.string.inv_invalid)
        }
    FinalState(text)
    FilledTonalButton(
        onClick = onClose,
        modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.primaryAction),
    ) { Text(stringResource(R.string.sharing_close)) }
}

/** Prénom de qui invite ; sans prénom, « Quelqu'un ». */
@Composable
private fun inviterOf(state: InvitationLinkUiState): String =
    state.preview?.inviterName?.takeIf { it.isNotBlank() } ?: stringResource(R.string.inv_someone)

/** Invitation envoyée à une autre adresse (Q4) : avertissement, puis acceptation possible. */
@Composable
private fun OtherAddressWarning(
    state: InvitationLinkUiState,
    inviter: String,
) {
    NoticeCard(Modifier.fillMaxWidth().testTag(TAG_INVITATION_OTHER)) {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Warning, contentDescription = null, tint = Ticket.colors.caution)
                Text(
                    stringResource(R.string.inv_other_title),
                    style = MaterialTheme.typography.bodyMedium.copy(fontWeight = FontWeight.Bold),
                    color = Ticket.colors.ink,
                    modifier = Modifier.padding(start = TicketDimens.spaceXs).semantics { heading() },
                )
            }
            Text(
                stringResource(
                    R.string.inv_other_body,
                    state.preview?.invitedEmailMasked.orEmpty(),
                    state.accountEmail.orEmpty(),
                    inviter,
                ),
                style = MaterialTheme.typography.bodyMedium,
                color = Ticket.colors.ink,
            )
        }
    }
}

@Composable
private fun FinalState(text: String) {
    Column(
        Modifier.fillMaxWidth().padding(top = TicketDimens.spaceL).testTag(TAG_INVITATION_FINAL),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
    ) {
        Icon(
            Icons.Outlined.Info,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(40.dp),
        )
        Text(
            text,
            style = MaterialTheme.typography.bodyLarge,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
        )
    }
}

/** Invitation ouverte par son lien, branchée sur son modèle. */
@Composable
fun InvitationLinkRoute(
    viewModel: InvitationLinkViewModel,
    onOpenList: (String) -> Unit,
    onSwitchAccount: () -> Unit,
    onClose: () -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val alreadyMember = stringResource(R.string.inv_member)
    LaunchedEffect(state.openList) {
        state.openList?.let {
            // Déjà membre (acceptation idempotente) : la liste s'ouvre, avec un message bref (maquette §5).
            if (state.outcome == AcceptOutcome.AlreadyMember) {
                Toast.makeText(context, alreadyMember, Toast.LENGTH_SHORT).show()
            }
            viewModel.listOpened()
            onOpenList(it)
        }
    }
    InvitationLinkScreen(state, viewModel::accept, viewModel::retry, onSwitchAccount, onClose)
}
