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

// Invitations reçues (#87 §9.5, maquette §5) et invitation d'un compte anonyme.

/** « Invitations (n) » : une carte par invitation. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReceivedInvitationsScreen(
    state: InvitationsUiState,
    onAccept: (ReceivedInvitation) -> Unit,
    onDecline: (ReceivedInvitation) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = pluralStringResource(R.plurals.inv_entry, state.invitations.size, state.invitations.size)
    Scaffold(
        modifier = modifier,
        containerColor = Ticket.colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Ticket.colors.desk),
                title = { Text(title, modifier = Modifier.semantics { heading() }) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Default.Close, contentDescription = stringResource(R.string.sharing_close))
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(bottom = TicketDimens.spaceL),
        ) {
            items(state.invitations, key = { it.id.toString() }) { invitation ->
                InvitationItem(invitation, state, onAccept, onDecline, label = stringResource(R.string.inv_sheet))
            }
        }
    }
}

/** Écran des invitations branché sur son modèle : une liste acceptée s'ouvre. */
@Composable
fun ReceivedInvitationsRoute(
    viewModel: InvitationsViewModel,
    onOpenList: (String) -> Unit,
    onBack: () -> Unit,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(state.openList) {
        state.openList?.let {
            viewModel.listOpened()
            onOpenList(it)
        }
    }
    ReceivedInvitationsScreen(state, viewModel::accept, viewModel::decline, onBack)
}

/** Compte anonyme, « Mes listes » : l'invitation se retrouve après la connexion avec l'adresse qui l'a reçue. */
@Composable
internal fun AnonymousInvitationHint(onSignIn: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(TicketDimens.spaceL).testTag(TAG_INVITATION_ANON),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
    ) {
        Icon(
            Icons.Default.Email,
            contentDescription = null,
            tint = Ticket.colors.inkMuted,
            modifier = Modifier.size(32.dp),
        )
        Text(
            stringResource(R.string.inv_anon_empty),
            style = MaterialTheme.typography.bodyMedium,
            color = Ticket.colors.ink,
            textAlign = TextAlign.Center,
        )
        FilledTonalButton(onClick = onSignIn, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
            Text(stringResource(R.string.lists_sign_in))
        }
    }
}
