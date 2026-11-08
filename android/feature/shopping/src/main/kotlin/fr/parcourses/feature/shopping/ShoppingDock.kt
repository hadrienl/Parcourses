package fr.parcourses.feature.shopping

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.KeyboardActionHandler
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

/** Dock en bas : annulation, saisie et « Terminer ». Empilé quand le texte est très agrandi (200 %). */
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
    val stacked = LocalDensity.current.fontScale >= STACK_FONT_SCALE
    Surface(tonalElevation = 3.dp, modifier = Modifier.imePadding()) {
        Column(
            Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            state.undo?.let { UndoBanner(it, actions.onUndo) }
            if (state.isEverythingChecked) {
                Text(stringResource(R.string.shopping_all_checked), style = MaterialTheme.typography.titleMedium)
            }
            val field: @Composable (Modifier) -> Unit = { modifier ->
                OutlinedTextField(
                    state = input,
                    label = { Text(stringResource(R.string.shopping_input_label)) },
                    lineLimits = TextFieldLineLimits.SingleLine,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    onKeyboardAction = KeyboardActionHandler { actions.onSubmit() },
                    trailingIcon = {
                        IconButton(onClick = actions.onSubmit, enabled = input.text.isNotBlank()) {
                            Icon(Icons.Default.Add, contentDescription = stringResource(R.string.shopping_add))
                        }
                    },
                    modifier = modifier.onFocusChanged { focused = it.isFocused }.testTag(TAG_ENTRY),
                )
            }
            val finish: @Composable (Modifier) -> Unit = { modifier ->
                Button(onClick = onFinish, modifier = modifier.heightIn(min = 48.dp).testTag(TAG_FINISH)) {
                    Text(stringResource(R.string.shopping_finish))
                }
            }
            if (stacked) {
                field(Modifier.fillMaxWidth())
                finish(Modifier.fillMaxWidth())
            } else {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    field(Modifier.weight(1f))
                    finish(Modifier)
                }
            }
        }
    }
}

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
            TextButton(onClick = onUndo, modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_UNDO)) {
                Text(stringResource(R.string.shopping_undo))
            }
        },
    ) {
        Text(message)
    }
}
