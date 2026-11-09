package fr.parcourses.feature.shopping

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.union
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import fr.parcourses.core.designsystem.DockPill
import fr.parcourses.core.designsystem.Ticket
import fr.parcourses.core.designsystem.TicketDimens
import fr.parcourses.core.designsystem.TicketType
import fr.parcourses.core.designsystem.dockFieldColors
import fr.parcourses.core.designsystem.dockFieldTextStyle
import fr.parcourses.core.designsystem.isLargeText

/**
 * Bas de l'écran, à portée du pouce (#6, B3 Android) : la barre « Annuler » au-dessus, puis la barre flottante de
 * saisie (ajout en route) et le bouton d'action « Terminer ». Empilés quand le texte est très agrandi (200 %).
 */
@Composable
internal fun Dock(
    state: ShoppingUiState,
    input: TextFieldState,
    actions: ShoppingActions,
    onFinish: () -> Unit,
) {
    var focused by remember { mutableStateOf(false) }
    LaunchedEffect(focused) {
        snapshotFlow { input.text.isNotEmpty() }.collect { actions.onEditing(focused) }
    }
    val stacked = isLargeText()
    Column(
        Modifier
            .windowInsetsPadding(WindowInsets.navigationBars.union(WindowInsets.ime))
            .padding(horizontal = TicketDimens.spaceM, vertical = TicketDimens.spaceXs),
        verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        state.undo?.let { UndoBanner(it, actions.onUndo) }
        if (state.isEverythingChecked) {
            Text(
                stringResource(R.string.shopping_all_checked),
                style = TicketType.title.copy(fontSize = MaterialTheme.typography.titleMedium.fontSize),
                color = Ticket.colors.ink,
            )
        }
        val field: @Composable (Modifier) -> Unit = { modifier ->
            EntryField(input, actions, onFocus = { focused = it }, modifier)
        }
        val finish: @Composable (Modifier) -> Unit = { modifier ->
            ExtendedFloatingActionButton(
                onClick = onFinish,
                icon = { Icon(Icons.Default.Check, contentDescription = null) },
                text = { Text(stringResource(R.string.shopping_finish)) },
                containerColor = Ticket.colors.accent,
                contentColor = Ticket.colors.onAccent,
                modifier = modifier.heightIn(min = TicketDimens.primaryAction).testTag(TAG_FINISH),
            )
        }
        if (stacked) {
            field(Modifier.fillMaxWidth())
            finish(Modifier.fillMaxWidth())
        } else {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
            ) {
                field(Modifier.weight(1f))
                finish(Modifier)
            }
        }
    }
}

/** Ajout en route : le champ dans la barre flottante, et son bouton « Ajouter ». */
@Composable
private fun EntryField(
    input: TextFieldState,
    actions: ShoppingActions,
    onFocus: (Boolean) -> Unit,
    modifier: Modifier,
) {
    DockPill(modifier) {
        TextField(
            state = input,
            label = { Text(stringResource(R.string.shopping_input_label), fontFamily = FontFamily.Default) },
            textStyle = dockFieldTextStyle(),
            lineLimits = TextFieldLineLimits.SingleLine,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            onKeyboardAction = KeyboardActionHandler { actions.onSubmit() },
            colors = dockFieldColors(),
            modifier = Modifier.weight(1f).onFocusChanged { onFocus(it.isFocused) }.testTag(TAG_ENTRY),
        )
        IconButton(onClick = actions.onSubmit, enabled = input.text.isNotBlank()) {
            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.shopping_add))
        }
    }
}

/** Barre « Annuler » (Snackbar Material) : encre sur papier inversé, action à l'accent inversé. */
@Composable
internal fun UndoBanner(
    undo: ShoppingUndo,
    onUndo: () -> Unit,
) {
    val message =
        when (undo.kind) {
            ShoppingUndo.Kind.Check -> stringResource(R.string.shopping_undo_checked, undo.label)
            ShoppingUndo.Kind.NotFound -> stringResource(R.string.shopping_undo_not_found, undo.label)
        }
    Snackbar(
        modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite }.testTag(TAG_UNDO_BANNER),
        action = {
            TextButton(onClick = onUndo, modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_UNDO)) {
                Text(stringResource(R.string.shopping_undo), color = Ticket.colors.inverseAccent)
            }
        },
    ) {
        Text(message, modifier = Modifier.padding(vertical = 4.dp))
    }
}
