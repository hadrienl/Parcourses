package fr.parcourses.app

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import fr.parcourses.core.data.account.PurgeFailure
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens

/**
 * « Nous écrire » (#129) : la messagerie s'ouvre sur `PurgeFailure.supportMailto`, objet seul (« Parcourses : purge
 * impossible (purge-signout-store) »), sans corps ni donnée personnelle. L'objet est aussi passé à part : toutes les
 * messageries ne lisent pas celui de l'adresse. Faux si aucune messagerie ne s'ouvre : l'écran affiche alors l'adresse
 * ([PurgeSupportAddress]), comme « Écrire un e-mail » de la suppression (#122).
 */
internal fun openPurgeSupport(
    context: Context,
    failure: PurgeFailure,
): Boolean {
    val intent =
        Intent(Intent.ACTION_SENDTO, failure.supportMailto.toUri())
            .putExtra(Intent.EXTRA_SUBJECT, failure.supportSubject)
    return try {
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        Log.i(TAG, "Aucune messagerie : ${failure.publicCode}")
        false
    } catch (_: SecurityException) {
        // Messagerie dont l'écran n'est pas ouvert aux autres apps : même repli.
        Log.i(TAG, "Messagerie inaccessible : ${failure.publicCode}")
        false
    }
}

/** Adresse de contact en texte sélectionnable, quand aucune messagerie ne s'ouvre. */
@Composable
internal fun PurgeSupportAddress(
    tag: String,
    modifier: Modifier = Modifier,
) {
    SelectionContainer(modifier.testTag(tag)) {
        Text(
            PurgeFailure.SUPPORT_ADDRESS,
            style = MaterialTheme.typography.bodyLarge,
            fontWeight = FontWeight.SemiBold,
            color = Ticket.colors.ink,
        )
    }
}

/**
 * Bandeau « Changement de compte inachevé » de l'écran Compte (#129) : `account.switch` laissé par un rejeu en échec,
 * seuil franchi, synchronisation arrêtée. « Réessayer » relance le rejeu ; « Nous écrire » ouvre la messagerie, sinon
 * affiche l'adresse. Il disparaît dès que le rejeu aboutit (compteur remis à 0).
 */
@Composable
internal fun SwitchBlockedBanner(
    failure: PurgeFailure,
    onRetry: () -> Unit,
) {
    val colors = Ticket.colors
    val context = LocalContext.current
    var noMailApp by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = TicketDimens.spaceM)
                .border(1.dp, colors.paperEdge, RoundedCornerShape(TicketDimens.radius))
                .padding(TicketDimens.spaceS)
                .testTag(TAG_SWITCH_BLOCKED),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        // Titre et texte lus ensemble, annoncés à l'apparition du bandeau.
        Column(
            modifier = Modifier.semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
            verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Warning, contentDescription = null, tint = colors.ink)
                Text(
                    stringResource(R.string.account_switch_blocked_title),
                    style = MaterialTheme.typography.titleSmall,
                    color = colors.ink,
                    modifier =
                        Modifier
                            .weight(1f)
                            .padding(start = TicketDimens.spaceXs)
                            .semantics { heading() },
                )
            }
            Text(
                stringResource(R.string.account_switch_blocked_body),
                style = MaterialTheme.typography.bodyMedium,
                color = colors.ink,
            )
        }
        if (noMailApp) PurgeSupportAddress(TAG_SWITCH_BLOCKED_CONTACT_ADDRESS)
        Button(
            onClick = onRetry,
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
            modifier = Modifier.fillMaxWidth().heightIn(min = TicketDimens.touchMin).testTag(TAG_SWITCH_BLOCKED_RETRY),
        ) { Text(stringResource(R.string.account_retry)) }
        OutlinedButton(
            onClick = { if (!openPurgeSupport(context, failure)) noMailApp = true },
            modifier =
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = TicketDimens.touchMin)
                    .testTag(TAG_SWITCH_BLOCKED_CONTACT),
        ) { Text(stringResource(R.string.purge_contact)) }
    }
}

private const val TAG = "PurgeSupport"

internal const val TAG_SWITCH_BLOCKED = "account-switch-blocked"
internal const val TAG_SWITCH_BLOCKED_RETRY = "account-switch-blocked-retry"
internal const val TAG_SWITCH_BLOCKED_CONTACT = "account-switch-blocked-contact"
internal const val TAG_SWITCH_BLOCKED_CONTACT_ADDRESS = "account-switch-blocked-contact-address"
