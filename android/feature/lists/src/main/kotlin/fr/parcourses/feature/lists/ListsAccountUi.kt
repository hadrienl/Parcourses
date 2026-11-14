package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens

/**
 * Compte, vu de l'écran Listes (#87) : « Se connecter » tant que le compte est anonyme ([canSignIn]), bandeau
 * « Reconnectez-vous pour synchroniser » quand un compte e-mail a perdu sa session ([needsSignIn]).
 */
@Immutable
data class ListsAccountUi(
    val canSignIn: Boolean = false,
    val needsSignIn: Boolean = false,
    val onSignIn: () -> Unit = {},
    /** Après confirmation : compte anonyme, les listes partagées avec soi quittent l'appareil. */
    val onContinueWithoutAccount: () -> Unit = {},
)

/** Compte e-mail sans session (#87, vecteur `009`) : rien ne se synchronise tant qu'on ne se reconnecte pas. */
@Composable
internal fun SessionLostBanner(
    onReconnect: () -> Unit,
    onAnonymous: () -> Unit,
) {
    val colors = Ticket.colors
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceS)
                .border(1.dp, colors.paperEdge, RoundedCornerShape(TicketDimens.radius))
                .padding(TicketDimens.spaceS)
                .testTag(TAG_SESSION_BANNER),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Lock, contentDescription = null, tint = colors.ink)
            Text(
                stringResource(R.string.lists_session_lost),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.ink,
                modifier =
                    Modifier
                        .weight(1f)
                        .padding(start = TicketDimens.spaceXs)
                        .semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
        Button(
            onClick = onReconnect,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin).testTag(TAG_SESSION_RECONNECT),
        ) { Text(stringResource(R.string.lists_session_reconnect)) }
        TextButton(
            onClick = onAnonymous,
            modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_SESSION_ANONYMOUS),
        ) { Text(stringResource(R.string.lists_session_anonymous), color = colors.ink) }
    }
}

@Composable
internal fun ContinueWithoutAccountDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.lists_anonymous_title)) },
        text = { Text(stringResource(R.string.lists_anonymous_body)) },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_ANONYMOUS_CONFIRM),
            ) { Text(stringResource(R.string.lists_anonymous_action), color = Ticket.colors.destructive) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, modifier = Modifier.heightIn(min = TicketDimens.touchMin)) {
                Text(stringResource(R.string.common_cancel))
            }
        },
    )
}

internal const val TAG_SESSION_BANNER = "lists-session-banner"
internal const val TAG_SESSION_RECONNECT = "lists-session-reconnect"
internal const val TAG_SESSION_ANONYMOUS = "lists-session-anonymous"
internal const val TAG_ANONYMOUS_CONFIRM = "lists-anonymous-confirm"
