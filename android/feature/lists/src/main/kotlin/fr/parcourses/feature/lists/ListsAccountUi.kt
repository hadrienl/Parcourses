package fr.parcourses.feature.lists

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import fr.parcourses.core.data.account.AccountEntry
import fr.parcourses.core.designsystem.MemberAvatar
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens

/**
 * Compte, vu de l'écran Listes (#87, #108) : bouton compte toujours visible ([entry]), « Se connecter » pour un compte
 * anonyme, pastille de l'initiale qui ouvre l'écran Compte pour un compte e-mail ; bandeau « Reconnectez-vous pour
 * synchroniser » quand un compte e-mail a perdu sa session ([needsSignIn]).
 */
@Immutable
data class ListsAccountUi(
    /** Bouton compte de la barre ; `null` sans serveur (rien à quoi se connecter). */
    val entry: AccountEntry? = null,
    /** Prénom lu avec la pastille : « Compte, Hadrien ». */
    val displayName: String? = null,
    /** Déconnexion inachevée : le bouton reste visible, désactivé (seul « Réessayer » est proposé). */
    val entryEnabled: Boolean = true,
    val needsSignIn: Boolean = false,
    /** Modifications pas encore envoyées : « Continuer sans compte » prévient qu'elles seront perdues. */
    val unsentChanges: Int = 0,
    val onSignIn: () -> Unit = {},
    /** Pastille d'un compte e-mail : l'écran Compte. */
    val onAccount: () -> Unit = {},
    /** Après confirmation : l'appareil est purgé, puis un compte anonyme vide est créé. */
    val onContinueWithoutAccount: () -> Unit = {},
) {
    /** Compte anonyme, rien en cours : « Se connecter » en haut, et sous les listes pour une invitation reçue. */
    val canSignIn: Boolean get() = entry == AccountEntry.SignIn && entryEnabled
}

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
    unsentChanges: Int,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.lists_anonymous_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS)) {
                Text(stringResource(R.string.lists_anonymous_body))
                if (unsentChanges > 0) Text(stringResource(R.string.lists_anonymous_unsent))
            }
        },
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

/**
 * Bouton compte de la barre (#108) : « Se connecter » pour un compte anonyme ; pour un compte e-mail, pastille de
 * l'initiale (même dessin que celles des membres), ou icône personne sans prénom, dans une cible de 48 dp.
 */
@Composable
internal fun AccountButton(account: ListsAccountUi) {
    when (val entry = account.entry) {
        null -> {
            Unit
        }

        AccountEntry.SignIn -> {
            TextButton(
                onClick = account.onSignIn,
                enabled = account.entryEnabled,
                colors = ButtonDefaults.textButtonColors(contentColor = Ticket.colors.accent),
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_SIGN_IN),
            ) { Text(stringResource(R.string.lists_sign_in)) }
        }

        is AccountEntry.Account -> {
            val label = accountLabel(account.displayName, account.needsSignIn)
            // Pas d'`IconButton` : il ne prend pas d'indication d'action (« Appuyez deux fois pour ouvrir votre
            // compte », l'`accessibilityHint` d'iOS). Même cible : 40 dp visibles, 48 dp au toucher.
            Box(
                modifier =
                    Modifier
                        .minimumInteractiveComponentSize()
                        .size(ACCOUNT_BUTTON_SIZE)
                        .clip(CircleShape)
                        .clickable(
                            enabled = account.entryEnabled,
                            onClickLabel = stringResource(R.string.lists_account_hint),
                            role = Role.Button,
                            onClick = account.onAccount,
                        ).semantics { contentDescription = label }
                        .testTag(TAG_ACCOUNT),
                contentAlignment = Alignment.Center,
            ) {
                // Désactivé : la pastille garde ses couleurs, elle s'efface comme une icône désactivée.
                val dim = Modifier.alpha(if (account.entryEnabled) 1f else DISABLED_ALPHA)
                val initial = entry.initial
                if (initial != null) {
                    MemberAvatar(initial, dim.testTag(TAG_ACCOUNT_INITIAL), size = ACCOUNT_AVATAR_SIZE)
                } else {
                    Icon(Icons.Filled.Person, contentDescription = null, tint = Ticket.colors.accent, modifier = dim)
                }
            }
        }
    }
}

/** « Compte, Hadrien » ou « Compte » ; session perdue : « … Reconnectez-vous pour synchroniser ». */
@Composable
private fun accountLabel(
    displayName: String?,
    needsSignIn: Boolean,
): String {
    val name = displayName?.trim()?.takeIf { it.isNotEmpty() }
    val base =
        if (name != null) stringResource(R.string.lists_account_named, name) else stringResource(R.string.lists_account)
    return if (needsSignIn) stringResource(R.string.lists_account_reconnect, base) else base
}

/** Pastille du bouton compte : 32 dp dans la cible de 48 dp (iOS : 28 pt dans 44 pt). */
private val ACCOUNT_AVATAR_SIZE = 32.dp

/** Taille visible du bouton, celle d'un `IconButton` ; la cible tactile monte à 48 dp. */
private val ACCOUNT_BUTTON_SIZE = 40.dp

/** Opacité Material d'un élément désactivé. */
private const val DISABLED_ALPHA = 0.38f

internal const val TAG_ACCOUNT = "lists-account"
internal const val TAG_ACCOUNT_INITIAL = "lists-account-initial"
internal const val TAG_SESSION_BANNER = "lists-session-banner"
internal const val TAG_SESSION_RECONNECT = "lists-session-reconnect"
internal const val TAG_SESSION_ANONYMOUS = "lists-session-anonymous"
internal const val TAG_ANONYMOUS_CONFIRM = "lists-anonymous-confirm"
