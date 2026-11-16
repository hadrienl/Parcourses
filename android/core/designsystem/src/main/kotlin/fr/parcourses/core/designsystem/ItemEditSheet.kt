package fr.parcourses.core.designsystem

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.InputTransformation
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.foundation.text.input.clearText
import androidx.compose.foundation.text.input.maxLength
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.foundation.text.input.setTextAndPlaceCursorAtEnd
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import fr.parcourses.core.categorizer.ItemQuantity
import fr.parcourses.core.categorizer.QuantityUnit
import kotlinx.coroutines.launch

/** Longueur maximale du libellé (`list_items.label`). */
private const val MAX_LABEL_LENGTH = 200

/**
 * Panneau de l'article (#110), à mi-hauteur : libellé modifiable, − / + sur le nombre, champ libre de quantité,
 * raccourcis g / kg / l et « Effacer la quantité ». Partagé par l'écran Liste et le mode courses.
 *
 * Rien n'est écrit avant « Enregistrer », qui rend le texte des deux champs à [onSave] (l'appelant le nettoie et
 * reclasse le libellé) ; fermer la feuille autrement (glisser, toucher à côté, Retour, « Annuler ») appelle seulement
 * [onDismiss]. Le brouillon survit à la rotation.
 */
@Composable
fun ItemEditSheet(
    target: ItemEditTarget,
    onSave: (label: String, quantityText: String) -> Unit,
    onDismiss: () -> Unit,
) {
    // Un autre article ouvert à la place repart de ses propres valeurs.
    key(target.id) { ItemEditSheetContent(target, onSave, onDismiss) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ItemEditSheetContent(
    target: ItemEditTarget,
    onSave: (label: String, quantityText: String) -> Unit,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = isLargeText())
    val scope = rememberCoroutineScope()
    val label = rememberTextFieldState(target.label)
    val quantity = rememberTextFieldState(target.quantity.orEmpty())
    // La feuille se range avant de disparaître : l'animation de sortie n'est pas coupée.
    val close = { scope.launch { sheetState.hide() }.invokeOnCompletion { onDismiss() } }
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Ticket.colors.paper,
        modifier = Modifier.testTag(TAG_ITEM_EDIT_SHEET),
    ) {
        Column(
            Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = TicketDimens.spaceM)
                .padding(bottom = TicketDimens.spaceL),
            verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceS),
        ) {
            Text(
                stringResource(R.string.item_edit_title),
                style = MaterialTheme.typography.titleLarge,
                color = Ticket.colors.ink,
                modifier = Modifier.semantics { heading() },
            )
            LabelField(label)
            QuantityRow(quantity)
            UnitShortcuts(quantity)
            TextButton(
                onClick = { quantity.clearText() },
                enabled = quantity.text.isNotEmpty(),
                modifier = Modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_ITEM_EDIT_CLEAR),
            ) { Text(stringResource(R.string.item_edit_clear), fontFamily = FontFamily.Default) }
            SheetButtons(
                canSave = label.text.isNotBlank(),
                onCancel = { close() },
                onSave = {
                    onSave(label.text.toString(), quantity.text.toString())
                    close()
                },
            )
        }
    }
}

@Composable
private fun LabelField(state: TextFieldState) {
    OutlinedTextField(
        state = state,
        label = { Text(stringResource(R.string.item_edit_label), fontFamily = FontFamily.Default) },
        inputTransformation = InputTransformation.maxLength(MAX_LABEL_LENGTH),
        lineLimits = TextFieldLineLimits.SingleLine,
        textStyle = dockFieldTextStyle(),
        keyboardOptions =
            KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Next),
        modifier = Modifier.fillMaxWidth().testTag(TAG_ITEM_EDIT_LABEL),
    )
}

/** − , champ libre, + : les boutons n'agissent que sur un nombre en tête, inactifs sinon. */
@Composable
private fun QuantityRow(state: TextFieldState) {
    val current = ItemQuantity.quantityInput(state.text.toString())
    val decreased = ItemQuantity.stepQuantity(current, -1)
    val increased = ItemQuantity.stepQuantity(current, 1)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs),
    ) {
        StepButton(
            glyph = MINUS,
            description = stringResource(R.string.item_edit_decrease),
            result = decreased,
            state = state,
            modifier = Modifier.testTag(TAG_ITEM_EDIT_DECREASE),
        )
        OutlinedTextField(
            state = state,
            label = { Text(stringResource(R.string.item_edit_quantity), fontFamily = FontFamily.Default) },
            placeholder = { Text(stringResource(R.string.item_edit_quantity_hint), fontFamily = FontFamily.Default) },
            inputTransformation = InputTransformation.maxLength(ItemQuantity.MAX_QUANTITY_LENGTH),
            lineLimits = TextFieldLineLimits.SingleLine,
            textStyle = dockFieldTextStyle(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Done),
            modifier = Modifier.weight(1f).testTag(TAG_ITEM_EDIT_QUANTITY),
        )
        StepButton(
            glyph = PLUS,
            description = stringResource(R.string.item_edit_increase),
            result = increased,
            state = state,
            modifier = Modifier.testTag(TAG_ITEM_EDIT_INCREASE),
        )
    }
}

/** Bouton − ou + : [result] est la quantité après l'appui, `null` quand le bouton est inactif. */
@Composable
private fun StepButton(
    glyph: String,
    description: String,
    result: String?,
    state: TextFieldState,
    modifier: Modifier,
) {
    FilledTonalIconButton(
        onClick = { result?.let(state::setTextAndPlaceCursorAtEnd) },
        enabled = result != null,
        colors =
            IconButtonDefaults.filledTonalIconButtonColors(
                containerColor = Ticket.colors.accentFill,
                contentColor = Ticket.colors.ink,
            ),
        modifier =
            modifier
                .sizeIn(minWidth = TicketDimens.touchMin, minHeight = TicketDimens.touchMin)
                .semantics { contentDescription = description },
    ) {
        Text(glyph, style = TicketType.itemNext, modifier = Modifier.clearAndSetSemantics { })
    }
}

/** Raccourcis g / kg / l : puces à bascule, la sélectionnée est l'unité de la quantité. */
@Composable
private fun UnitShortcuts(state: TextFieldState) {
    val current = ItemQuantity.quantityInput(state.text.toString())
    val selected = ItemQuantity.quantityUnit(current)
    Row(horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
        QuantityUnit.entries.forEach { unit ->
            val result = ItemQuantity.setQuantityUnit(current, unit)
            val description = stringResource(unitDescription(unit))
            FilterChip(
                selected = selected == unit,
                onClick = { result?.let(state::setTextAndPlaceCursorAtEnd) },
                enabled = result != null,
                label = { Text(unit.symbol, style = TicketType.item) },
                colors =
                    FilterChipDefaults.filterChipColors(
                        containerColor = Ticket.colors.paper,
                        labelColor = Ticket.colors.ink,
                        selectedContainerColor = Ticket.colors.accentFill,
                        selectedLabelColor = Ticket.colors.ink,
                    ),
                modifier =
                    Modifier
                        .heightIn(min = TicketDimens.touchMin)
                        .semantics { contentDescription = description }
                        .testTag("$TAG_ITEM_EDIT_UNIT-${unit.symbol}"),
            )
        }
    }
}

private fun unitDescription(unit: QuantityUnit): Int =
    when (unit) {
        QuantityUnit.Gram -> R.string.item_edit_unit_g
        QuantityUnit.Kilogram -> R.string.item_edit_unit_kg
        QuantityUnit.Liter -> R.string.item_edit_unit_l
    }

/** « Annuler » puis « Enregistrer », à portée du pouce ; empilés quand le texte est très agrandi. */
@Composable
private fun SheetButtons(
    canSave: Boolean,
    onCancel: () -> Unit,
    onSave: () -> Unit,
) {
    val cancel: @Composable (Modifier) -> Unit = { modifier ->
        TextButton(onClick = onCancel, modifier = modifier.heightIn(min = TicketDimens.touchMin)) {
            Text(stringResource(R.string.item_edit_cancel), color = Ticket.colors.accent)
        }
    }
    val save: @Composable (Modifier) -> Unit = { modifier ->
        Button(
            onClick = onSave,
            enabled = canSave,
            colors =
                ButtonDefaults.buttonColors(
                    containerColor = Ticket.colors.accent,
                    contentColor = Ticket.colors.onAccent,
                ),
            modifier = modifier.heightIn(min = TicketDimens.touchMin).testTag(TAG_ITEM_EDIT_SAVE),
        ) { Text(stringResource(R.string.item_edit_save)) }
    }
    if (isLargeText()) {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs)) {
            save(Modifier.fillMaxWidth())
            cancel(Modifier.fillMaxWidth())
        }
    } else {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(TicketDimens.spaceXs, Alignment.End),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            cancel(Modifier)
            save(Modifier)
        }
    }
}

/** Signe moins typographique (U+2212) et plus : lus par leur description, pas par le glyphe. */
private const val MINUS = "−"
private const val PLUS = "+"

const val TAG_ITEM_EDIT_SHEET = "item-edit-sheet"
const val TAG_ITEM_EDIT_LABEL = "item-edit-label"
const val TAG_ITEM_EDIT_QUANTITY = "item-edit-quantity"
const val TAG_ITEM_EDIT_DECREASE = "item-edit-decrease"
const val TAG_ITEM_EDIT_INCREASE = "item-edit-increase"
const val TAG_ITEM_EDIT_UNIT = "item-edit-unit"
const val TAG_ITEM_EDIT_CLEAR = "item-edit-clear"
const val TAG_ITEM_EDIT_SAVE = "item-edit-save"
