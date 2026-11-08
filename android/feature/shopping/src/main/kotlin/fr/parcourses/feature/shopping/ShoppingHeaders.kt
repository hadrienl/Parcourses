package fr.parcourses.feature.shopping

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp

@Composable
internal fun Header(state: ShoppingUiState) {
    val knowledge =
        when (val k = state.knowledge) {
            RouteKnowledge.NoStore -> stringResource(R.string.shopping_knowledge_no_store)
            RouteKnowledge.Unknown -> stringResource(R.string.shopping_knowledge_unknown)
            is RouteKnowledge.Learning -> stringResource(R.string.shopping_knowledge_learning, k.percent)
            is RouteKnowledge.Learned -> stringResource(R.string.shopping_knowledge_learned, k.percent)
        }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics(mergeDescendants = true) { heading() }
            .testTag(TAG_HEADER),
    ) {
        Text(
            stringResource(R.string.shopping_remaining_header, state.toBuyCount),
            style = MaterialTheme.typography.titleLarge,
        )
        state.storeName?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
        Text(knowledge, style = MaterialTheme.typography.bodyMedium)
    }
}

/** Titre de rayon : lu comme un en-tête, avec le nombre d'articles à prendre. */
@Composable
internal fun AisleHeader(section: ShoppingSection) {
    val announcement = stringResource(R.string.shopping_aisle_count, section.title, section.remainingCount)
    Text(
        text = section.title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier =
            Modifier
                .fillMaxWidth()
                .background(MaterialTheme.colorScheme.surfaceContainer)
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .semantics {
                    heading()
                    contentDescription = announcement
                },
    )
}

@Composable
internal fun SectionTitle(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).semantics { heading() },
    )
}

@Composable
internal fun BasketHeader(
    count: Int,
    expanded: Boolean,
    onToggle: () -> Unit,
) {
    val title = stringResource(R.string.shopping_basket, count)
    val state =
        stringResource(if (expanded) R.string.shopping_basket_expanded else R.string.shopping_basket_collapsed)
    Text(
        title,
        style = MaterialTheme.typography.titleSmall,
        modifier =
            Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clickable(role = Role.Button, onClick = onToggle)
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .testTag(TAG_BASKET)
                .semantics { stateDescription = state },
    )
}
