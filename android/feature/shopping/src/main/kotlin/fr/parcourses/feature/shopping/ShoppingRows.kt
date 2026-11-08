package fr.parcourses.feature.shopping

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxState
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.distinctUntilChanged

/** Signale le début et la fin d'un balayage horizontal ; une ligne retirée en plein geste le termine. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SwipeTracker(
    state: SwipeToDismissBoxState,
    onSwiping: (Boolean) -> Unit,
) {
    val current by rememberUpdatedState(onSwiping)
    var swiping by remember { mutableStateOf(false) }
    LaunchedEffect(state) {
        snapshotFlow { state.dismissDirection != SwipeToDismissBoxValue.Settled }
            .distinctUntilChanged()
            .collect {
                swiping = it
                current(it)
            }
    }
    DisposableEffect(state) { onDispose { if (swiping) current(false) } }
}

/**
 * Une ligne. Action par défaut : « Cocher » (ou « Décocher » si la ligne l'est déjà). Actions personnalisées pour
 * TalkBack : « Décocher » sur une ligne cochée, « Pas trouvé » sur une ligne à prendre ; le balayage n'est jamais la
 * seule voie. Le balayage : à droite coche, à gauche signale introuvable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ItemRow(
    row: ShoppingRow,
    highlighted: Boolean,
    actions: ShoppingActions,
    modifier: Modifier = Modifier,
) {
    // L'état du balayage survit aux recompositions : sans cela, il agirait sur la ligne d'avant (cochée entre-temps).
    val current by rememberUpdatedState(row)
    val swipe =
        rememberSwipeToDismissBoxState(
            confirmValueChange = { value ->
                val latest = current
                when (value) {
                    SwipeToDismissBoxValue.StartToEnd -> {
                        if (!latest.isChecked) {
                            actions.onCheckFeedback()
                            actions.onToggle(latest)
                        }
                    }

                    SwipeToDismissBoxValue.EndToStart -> {
                        if (!latest.isChecked) actions.onNotFound(latest)
                    }

                    SwipeToDismissBoxValue.Settled -> {
                        Unit
                    }
                }
                // La ligne revient à sa place : c'est la liste qui change, pas le geste.
                false
            },
        )
    SwipeTracker(swipe, actions.onSwiping)
    SwipeToDismissBox(
        state = swipe,
        modifier = modifier,
        enableDismissFromStartToEnd = !row.isChecked,
        enableDismissFromEndToStart = !row.isChecked,
        backgroundContent = {},
    ) {
        ItemRowContent(row, highlighted, actions)
    }
}

@Composable
internal fun ItemRowContent(
    row: ShoppingRow,
    highlighted: Boolean,
    actions: ShoppingActions,
) {
    val checkedText = stringResource(R.string.shopping_state_checked)
    val uncheckedText = stringResource(R.string.shopping_state_unchecked)
    val checkLabel = stringResource(R.string.shopping_action_check)
    val uncheckLabel = stringResource(R.string.shopping_action_uncheck)
    val notFoundLabel = stringResource(R.string.shopping_action_not_found)
    val custom =
        if (row.isChecked) {
            listOf(CustomAccessibilityAction(uncheckLabel) { actions.onToggle(row).let { true } })
        } else {
            listOf(CustomAccessibilityAction(notFoundLabel) { actions.onNotFound(row).let { true } })
        }
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .background(
                    if (highlighted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface,
                ).heightIn(min = 48.dp)
                .clickable(onClickLabel = if (row.isChecked) uncheckLabel else checkLabel, role = Role.Checkbox) {
                    if (!row.isChecked) actions.onCheckFeedback()
                    actions.onToggle(row)
                }.semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = if (row.isChecked) checkedText else uncheckedText
                    customActions = custom
                }.padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // L'état se lit sans couleur : forme de l'icône et texte barré.
        Checkbox(checked = row.isChecked, onCheckedChange = null, modifier = Modifier.clearAndSetSemantics { })
        Text(
            text = row.label,
            style = MaterialTheme.typography.bodyLarge,
            textDecoration = if (row.isChecked) TextDecoration.LineThrough else null,
            color =
                if (row.isChecked) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
        )
        row.quantity?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
internal fun NotFoundRow(
    row: ShoppingRow,
    onRestore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state = stringResource(R.string.shopping_state_not_found)
    val hint = stringResource(R.string.shopping_restore_hint)
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(onClickLabel = hint, role = Role.Button, onClick = onRestore)
                .semantics(mergeDescendants = true) {
                    contentDescription = row.accessibilityLabel
                    stateDescription = state
                }.padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Info, contentDescription = null, modifier = Modifier.clearAndSetSemantics { })
        Text(row.label, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
        Text(
            stringResource(R.string.shopping_restore),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
