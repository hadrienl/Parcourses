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

/** Titre et explication lus d'un bloc ; annoncés quand l'état change. */
@Composable
internal fun Status(notice: Notice) {
    Column(
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier =
            Modifier
                .fillMaxWidth()
                .padding(16.dp)
                .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
    ) {
        Text(
            stringResource(notice.title),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            stringResource(notice.body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

internal fun LazyListScope.search(
    state: StorePickerUiState,
    query: TextFieldState,
    actions: StorePickerActions,
) {
    item(key = "search-field", contentType = "search") {
        OutlinedTextField(
            state = query,
            label = { Text(stringResource(R.string.picker_search_label)) },
            lineLimits = TextFieldLineLimits.SingleLine,
            keyboardOptions =
                KeyboardOptions(
                    capitalization = KeyboardCapitalization.Words,
                    autoCorrectEnabled = false,
                    imeAction = ImeAction.Search,
                ),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).testTag(TAG_SEARCH),
        )
    }
    when (val result = state.search) {
        StoreSearchState.Idle -> {
            // Rien à montrer tant que la saisie est trop courte.
        }

        StoreSearchState.Searching -> {
            searchMessage(R.string.picker_searching, progress = true)
        }

        is StoreSearchState.Results -> {
            if (result.stores.isEmpty()) {
                searchMessage(R.string.picker_search_none)
            } else {
                storeSection("results", R.string.picker_search_results, result.stores, actions)
            }
        }

        StoreSearchState.Offline -> {
            searchMessage(R.string.picker_search_offline)
        }

        StoreSearchState.Failed -> {
            searchMessage(R.string.picker_search_failed)
        }
    }
}

private fun LazyListScope.searchMessage(
    text: Int,
    progress: Boolean = false,
) {
    item(key = "search-message", contentType = "status") {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp)
                    .semantics(mergeDescendants = true) { liveRegion = LiveRegionMode.Polite },
        ) {
            if (progress) {
                CircularProgressIndicator(modifier = Modifier.width(20.dp).heightIn(max = 20.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(12.dp))
            }
            Text(
                stringResource(text),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

internal fun LazyListScope.storeSection(
    section: String,
    title: Int,
    stores: List<StoreCandidate>,
    actions: StorePickerActions,
) {
    if (stores.isEmpty()) return
    item(key = "$section-title", contentType = "title") { SectionTitle(stringResource(title)) }
    // Un magasin récent peut aussi être proche : la clé porte la section.
    items(stores.size, key = { "$section-${stores[it].id}" }, contentType = { "store" }) { index ->
        StoreRow(stores[index], actions.onSelect)
    }
}

internal fun LazyListScope.withoutStore(actions: StorePickerActions) {
    item(key = "without-store", contentType = "action") {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            HorizontalDivider(Modifier.padding(bottom = 8.dp))
            TextButton(
                onClick = actions.onContinueWithoutStore,
                modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_WITHOUT_STORE),
            ) { Text(stringResource(R.string.picker_without_store)) }
            Text(
                stringResource(R.string.picker_without_store_footer),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
internal fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp).semantics { heading() },
    )
}

/** Nom, adresse et distance si elle a un sens. Une seule cible, lue d'un bloc par TalkBack. */
@Composable
internal fun StoreRow(
    store: StoreCandidate,
    onSelect: (StoreCandidate) -> Unit,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 56.dp)
                .clickable(
                    role = Role.Button,
                    onClickLabel = stringResource(R.string.picker_store_action),
                    onClick = { onSelect(store) },
                ).padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(Modifier.weight(1f)) {
            Text(store.name, style = MaterialTheme.typography.bodyLarge)
            store.address?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        store.distanceM?.let {
            Spacer(Modifier.width(12.dp))
            Text(
                StoreDistance.text(it),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

/** Les magasins viennent d'OpenStreetMap : mention et lien vers la licence (ODbL). */
@Composable
internal fun Attribution() {
    val text = stringResource(R.string.picker_attribution)
    Surface(tonalElevation = 2.dp, modifier = Modifier.fillMaxWidth().testTag(TAG_ATTRIBUTION)) {
        Text(
            buildAnnotatedString {
                withLink(LinkAnnotation.Url(OSM_COPYRIGHT_URL)) { append(text) }
            },
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 14.dp),
        )
    }
}

@Composable
internal fun SelectionFailedDialog(actions: StorePickerActions) {
    AlertDialog(
        onDismissRequest = actions.onDismissSelectionFailure,
        title = { Text(stringResource(R.string.picker_save_failed_title)) },
        text = { Text(stringResource(R.string.picker_save_failed_body)) },
        confirmButton = {
            TextButton(onClick = actions.onDismissSelectionFailure) { Text(stringResource(R.string.picker_ok)) }
        },
    )
}
