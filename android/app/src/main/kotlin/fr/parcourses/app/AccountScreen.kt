package fr.parcourses.app

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
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
import fr.parcourses.core.designsystem.TicketSheet

/**
 * Écran Compte d'un compte e-mail (#108, maquette `design/sharing-v1.html` §9.4), ouvert par la pastille de l'écran
 * Listes ; iOS : `AccountView`. Dans l'ordre : « Reconnectez-vous » si la session a disparu, adresse, prénom
 * modifiable, note de confidentialité, « Se déconnecter » ([AccountViewModel]), puis « Vos données » (#68,
 * [AccountDeletionViewModel]). Un compte anonyme n'a pas d'écran Compte : la navigation le ferme.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AccountScreen(
    account: AccountUiState,
    accountActions: AccountActions,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    accountDeletion: AccountDeletionUiState = AccountDeletionUiState(),
    accountDeletionActions: AccountDeletionActions = AccountDeletionActions(),
) {
    val colors = Ticket.colors
    Scaffold(
        modifier = modifier,
        containerColor = colors.desk,
        topBar = {
            TopAppBar(
                colors = TopAppBarDefaults.topAppBarColors(containerColor = colors.desk),
                title = { Text(stringResource(R.string.account_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack, modifier = Modifier.testTag(TAG_ACCOUNT_BACK)) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.account_back),
                        )
                    }
                },
            )
        },
    ) { padding ->
        TicketSheet(Modifier.padding(padding)) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = TicketDimens.spaceM),
                verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
            ) {
                if (account.account.needsSignIn) ReconnectBanner(accountActions.onSignIn)
                AccountDetails(account, accountActions)
                InfoSection(stringResource(R.string.about_account_title)) {
                    AccountDeletionContent(accountDeletion, accountDeletionActions, isEmailAccount = true)
                }
            }
        }
    }
    AccountDialogs(account, accountActions)
}

/** Adresse, prénom modifiable, note de confidentialité, « Se déconnecter ». */
@Composable
private fun AccountDetails(
    state: AccountUiState,
    actions: AccountActions,
) {
    val colors = Ticket.colors
    Column {
        AccountRow(
            stringResource(R.string.account_email),
            state.account.email.orEmpty(),
            // Une adresse n'a pas d'espace : aux grandes polices, trop longue pour la ligne, elle se coupe au caractère
            // près (sans césure, `Hyphens.None` par défaut) plutôt que de déborder.
            Modifier.testTag(TAG_ACCOUNT_EMAIL),
        )
        val name = state.account.displayName ?: stringResource(R.string.account_name_missing)
        val editLabel = stringResource(R.string.account_name_edit)
        AccountRow(
            stringResource(R.string.account_name),
            name,
            Modifier
                // Session perdue : le prénom ne pourrait pas partir (comme iOS).
                .clickable(
                    enabled = !state.account.needsSignIn,
                    onClickLabel = editLabel,
                    onClick = actions.onEditName,
                ).testTag(TAG_ACCOUNT_NAME),
            trailingEdit = true,
        )
        Row(
            modifier = Modifier.padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
            horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Outlined.Lock,
                contentDescription = null,
                tint = colors.inkMuted,
                modifier = Modifier.size(size = 16.dp),
            )
            Text(
                stringResource(R.string.account_note),
                style = MaterialTheme.typography.bodySmall,
                color = colors.inkMuted,
            )
        }
        // Session perdue : on se reconnecte (bandeau du haut), ou on continue sans compte depuis les listes.
        if (!state.account.needsSignIn) {
            OutlinedButton(
                onClick = actions.onSignOutRequest,
                enabled = !state.signingOut,
                modifier =
                    Modifier
                        .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
                        .heightIn(min = TicketDimens.touchMin)
                        .testTag(TAG_ACCOUNT_SIGN_OUT),
            ) { Text(stringResource(R.string.account_sign_out)) }
        }
    }
}

/** Session disparue (vecteur `009`) : rien ne se synchronise tant qu'on ne se reconnecte pas. */
@Composable
private fun ReconnectBanner(onReconnect: () -> Unit) {
    val colors = Ticket.colors
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = TicketDimens.spaceM)
                .border(1.dp, colors.paperEdge, RoundedCornerShape(TicketDimens.radius))
                .padding(TicketDimens.spaceS)
                .testTag(TAG_ACCOUNT_SESSION_LOST),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Lock, contentDescription = null, tint = colors.ink)
            Text(
                stringResource(R.string.account_session_lost),
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
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin).testTag(TAG_ACCOUNT_RECONNECT),
        ) { Text(stringResource(R.string.account_reconnect)) }
    }
}

/**
 * Ligne de 56 dp au moins : libellé et valeur, lus en une seule annonce, avec l'action de la ligne s'il y en a une
 * (le prénom : « Modifier le prénom »).
 */
@Composable
private fun AccountRow(
    label: String,
    value: String,
    modifier: Modifier,
    trailingEdit: Boolean = false,
) {
    Row(
        modifier =
            modifier
                .semantics(mergeDescendants = true) {}
                .fillMaxWidth()
                .heightIn(min = TicketDimens.rowMin)
                .padding(horizontal = TicketDimens.spaceM),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.labelMedium, color = Ticket.colors.inkMuted)
            Text(value, style = MaterialTheme.typography.bodyLarge, color = Ticket.colors.ink)
        }
        if (trailingEdit) Icon(Icons.Default.Edit, contentDescription = null, tint = Ticket.colors.inkMuted)
    }
}

internal const val TAG_ACCOUNT_BACK = "account-back"
internal const val TAG_ACCOUNT_EMAIL = "account-email"
internal const val TAG_ACCOUNT_NAME = "account-name"
internal const val TAG_ACCOUNT_SESSION_LOST = "account-session-lost"
internal const val TAG_ACCOUNT_RECONNECT = "account-reconnect"
