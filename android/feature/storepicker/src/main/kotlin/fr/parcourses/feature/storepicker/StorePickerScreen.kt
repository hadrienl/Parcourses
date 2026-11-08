package fr.parcourses.feature.storepicker

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.withLink
import androidx.compose.ui.unit.dp

const val TAG_CONFIRM_PROPOSAL = "storepicker.confirm"
const val TAG_WITHOUT_STORE = "storepicker.withoutStore"
const val TAG_SEARCH = "storepicker.search"
const val TAG_PRIMARY_ACTION = "storepicker.primaryAction"
const val TAG_PRECISION = "storepicker.precision"
const val TAG_ATTRIBUTION = "storepicker.attribution"

/** Contenu de la page de licence demandée par l'ODbL. */
const val OSM_COPYRIGHT_URL = "https://www.openstreetmap.org/copyright"

/** Actions de l'écran, regroupées pour garder des signatures lisibles. */
@Immutable
class StorePickerActions(
    val onBack: () -> Unit,
    val onSelect: (StoreCandidate) -> Unit,
    /** Ouvre la demande système de localisation (ou, la seconde fois, la précision). */
    val onRequestPermission: () -> Unit,
    val onOpenSettings: () -> Unit,
    val onRetry: () -> Unit,
    val onContinueWithoutStore: () -> Unit,
    val onDismissSelectionFailure: () -> Unit,
)

/**
 * Choix du magasin. [query] est la saisie de la recherche par nom, tenue par l'appelant ; l'écran n'a pas d'état
 * propre.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StorePickerScreen(
    state: StorePickerUiState,
    query: TextFieldState,
    actions: StorePickerActions,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.picker_title)) },
                navigationIcon = {
                    IconButton(onClick = actions.onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.picker_back),
                        )
                    }
                },
            )
        },
        bottomBar = { Attribution() },
    ) { padding ->
        LazyColumn(
            contentPadding = padding,
            modifier = Modifier.fillMaxWidth(),
        ) {
            phaseContent(state, query, actions)
        }
    }
    if (state.selectionFailed) SelectionFailedDialog(actions)
}

private fun LazyListScope.phaseContent(
    state: StorePickerUiState,
    query: TextFieldState,
    actions: StorePickerActions,
) {
    val phase = state.phase
    when (phase) {
        StorePickerPhase.Loading -> {
            loading()
        }

        is StorePickerPhase.Precise -> {
            precise(phase, state, actions)
        }

        is StorePickerPhase.Approximate -> {
            approximate(phase, state, query, actions)
        }

        StorePickerPhase.PermissionNeeded -> {
            permissionNeeded(actions)
        }

        is StorePickerPhase.Denied -> {
            denied(phase, actions)
        }

        StorePickerPhase.LocationUnavailable -> {
            notice(Notice.Unavailable, R.string.picker_retry, actions.onRetry)
        }

        StorePickerPhase.Offline -> {
            notice(Notice.Offline, R.string.picker_retry, actions.onRetry)
        }

        StorePickerPhase.ServiceError -> {
            notice(Notice.Error, R.string.picker_retry, actions.onRetry)
        }

        StorePickerPhase.NoStore -> {
            notice(Notice.NoStore)
        }
    }
    // Les états sans liste de magasins proches : recherche par nom (si utile), récents, sortie sans magasin.
    val hasNearbyList = phase is StorePickerPhase.Precise || phase is StorePickerPhase.Approximate
    if (phase != StorePickerPhase.Loading && !hasNearbyList) fallbackSections(state, query, actions)
}

/** Titre et explication d'un état. */
internal enum class Notice(
    val title: Int,
    val body: Int,
) {
    Permission(R.string.picker_permission_title, R.string.picker_permission_body),
    Denied(R.string.picker_denied_title, R.string.picker_denied_body),
    Blocked(R.string.picker_denied_title, R.string.picker_denied_blocked_body),
    Unavailable(R.string.picker_unavailable_title, R.string.picker_unavailable_body),
    Offline(R.string.picker_offline_title, R.string.picker_offline_body),
    Error(R.string.picker_error_title, R.string.picker_error_body),
    NoStore(R.string.picker_no_store_title, R.string.picker_no_store_body),
    Approximate(R.string.picker_approximate_title, R.string.picker_approximate_body),
}

private fun LazyListScope.permissionNeeded(actions: StorePickerActions) =
    notice(Notice.Permission, R.string.picker_permission_allow, actions.onRequestPermission)

private fun LazyListScope.fallbackSections(
    state: StorePickerUiState,
    query: TextFieldState,
    actions: StorePickerActions,
) {
    if (state.offersSearch) search(state, query, actions)
    storeSection("recents", R.string.picker_recents, state.recents, actions)
    withoutStore(actions)
}

private fun LazyListScope.loading() {
    item(key = "loading", contentType = "status") {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(32.dp)
                    .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            CircularProgressIndicator()
            Text(stringResource(R.string.picker_loading), style = MaterialTheme.typography.bodyLarge)
        }
    }
}

private fun LazyListScope.precise(
    phase: StorePickerPhase.Precise,
    state: StorePickerUiState,
    actions: StorePickerActions,
) {
    val proposed = phase.proposed
    if (proposed != null) {
        item(key = "here-title", contentType = "title") { SectionTitle(stringResource(R.string.picker_here_title)) }
        item(key = "here-${proposed.id}", contentType = "store") { StoreRow(proposed, actions.onSelect) }
        item(key = "here-confirm", contentType = "action") {
            Button(
                onClick = { actions.onSelect(proposed) },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp).testTag(TAG_CONFIRM_PROPOSAL),
            ) { Text(stringResource(R.string.picker_confirm_here)) }
        }
    }
    val title = if (proposed == null) R.string.picker_nearby else R.string.picker_other_nearby
    storeSection("nearby", title, phase.others, actions)
    storeSection("recents", R.string.picker_recents, state.recents, actions)
    withoutStore(actions)
}

private fun LazyListScope.approximate(
    phase: StorePickerPhase.Approximate,
    state: StorePickerUiState,
    query: TextFieldState,
    actions: StorePickerActions,
) {
    item(key = "status", contentType = "status") {
        Status(Notice.Approximate)
    }
    item(key = "precision", contentType = "action") {
        OutlinedButton(
            onClick = actions.onRequestPermission,
            modifier = Modifier.padding(horizontal = 16.dp).testTag(TAG_PRECISION),
        ) { Text(stringResource(R.string.picker_use_precise)) }
    }
    if (state.precisionDeclined) {
        item(key = "precision-declined", contentType = "status") {
            Text(
                stringResource(R.string.picker_precise_declined),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(16.dp).semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
    search(state, query, actions)
    if (state.search == StoreSearchState.Idle) storeSection("sector", R.string.picker_sector, phase.candidates, actions)
    storeSection("recents", R.string.picker_recents, state.recents, actions)
    withoutStore(actions)
}

private fun LazyListScope.denied(
    phase: StorePickerPhase.Denied,
    actions: StorePickerActions,
) {
    if (phase.canAskAgain) {
        notice(Notice.Denied, R.string.picker_allow_again, actions.onRequestPermission)
    } else {
        notice(Notice.Blocked, R.string.picker_open_settings, actions.onOpenSettings)
    }
}

/** Explication d'un état, avec au plus une action principale. */
private fun LazyListScope.notice(
    notice: Notice,
    actionLabel: Int? = null,
    onAction: () -> Unit = {},
) {
    item(key = "status", contentType = "status") { Status(notice) }
    if (actionLabel != null) {
        item(key = "primary-action", contentType = "action") {
            Button(
                onClick = onAction,
                modifier = Modifier.padding(horizontal = 16.dp).testTag(TAG_PRIMARY_ACTION),
            ) { Text(stringResource(actionLabel)) }
        }
    }
}
