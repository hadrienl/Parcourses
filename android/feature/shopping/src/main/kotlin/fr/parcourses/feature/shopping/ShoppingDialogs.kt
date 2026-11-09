package fr.parcourses.feature.shopping

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.Ticket

/** « 2 articles non cochés : les garder pour la prochaine fois ? » (#6) */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun RemainingItemsSheet(
    count: Int,
    expired: Boolean,
    actions: ShoppingActions,
    onCancel: () -> Unit,
) {
    val sheet =
        rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { !expired })
    val colors = Ticket.colors
    ModalBottomSheet(
        onDismissRequest = { if (!expired) onCancel() },
        sheetState = sheet,
        containerColor = colors.paper,
        contentColor = colors.ink,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp).testTag(TAG_REMAINING_SHEET),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                pluralStringResource(R.plurals.shopping_remaining_title, count, count),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            if (expired) Text(stringResource(R.string.shopping_expired_note))
            Text(stringResource(R.string.shopping_remaining_question))
            Button(
                onClick = { actions.onFinish(true) },
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_KEEP),
            ) { Text(stringResource(R.string.shopping_keep)) }
            // Action destructive : rouge dédié, au moins 4,5:1 sur le papier de la feuille (iOS #60).
            OutlinedButton(
                onClick = { actions.onFinish(false) },
                colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.destructive),
                border = BorderStroke(1.dp, colors.destructive),
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_DROP),
            ) { Text(stringResource(R.string.shopping_drop)) }
            if (!expired) {
                TextButton(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag(TAG_CONTINUE),
                ) { Text(stringResource(R.string.shopping_continue)) }
            }
        }
    }
}

@Composable
internal fun ErrorDialog(
    message: String,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.shopping_error_title)) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.shopping_error_ok)) } },
    )
}
