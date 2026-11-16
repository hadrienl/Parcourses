package fr.parcourses.feature.lists

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import fr.parcourses.core.designsystem.NoticeCard
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens

/**
 * Astuce unique (#110) : discrète, au-dessus des articles, avec un bouton pour la fermer à jamais. Lue comme un texte,
 * sans déplacer le focus de TalkBack.
 */
@Composable
internal fun QuantityTip(onDismiss: () -> Unit) {
    NoticeCard(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs)
            .testTag(TAG_QUANTITY_TIP),
        caution = false,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Info, contentDescription = null, tint = Ticket.colors.ink)
            Text(
                stringResource(R.string.detail_quantity_tip),
                style = MaterialTheme.typography.bodyMedium,
                color = Ticket.colors.ink,
                modifier = Modifier.weight(1f).padding(horizontal = TicketDimens.spaceXs),
            )
            IconButton(onClick = onDismiss, modifier = Modifier.testTag(TAG_QUANTITY_TIP_CLOSE)) {
                Icon(
                    Icons.Default.Close,
                    contentDescription = stringResource(R.string.detail_quantity_tip_close),
                    tint = Ticket.colors.inkMuted,
                )
            }
        }
    }
}
