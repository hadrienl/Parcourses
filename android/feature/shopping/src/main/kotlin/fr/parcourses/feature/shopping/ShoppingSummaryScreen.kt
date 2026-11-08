package fr.parcourses.feature.shopping

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp

/** Fin des courses, version minimale : « 12 articles en 18 min » et la contribution. L'écran complet est A9. */
@Composable
fun ShoppingSummaryScreen(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val contribution =
        summary.storeName?.let { store ->
            when (val k = summary.knowledge) {
                RouteKnowledge.NoStore -> null
                RouteKnowledge.Unknown -> stringResource(R.string.shopping_summary_first, store)
                is RouteKnowledge.Learning -> stringResource(R.string.shopping_summary_known, store, k.percent)
                is RouteKnowledge.Learned -> stringResource(R.string.shopping_summary_known, store, k.percent)
            }
        }
    Scaffold(modifier = modifier) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                pluralStringResource(R.plurals.shopping_summary_articles, summary.checkedCount, summary.checkedCount),
                style = MaterialTheme.typography.displaySmall,
                modifier = Modifier.testTag(TAG_SUMMARY),
            )
            Text(
                stringResource(R.string.shopping_summary_minutes, summary.minutes),
                style = MaterialTheme.typography.titleLarge,
            )
            contribution?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            Button(onClick = onClose, modifier = Modifier.heightIn(min = 48.dp).testTag(TAG_CLOSE)) {
                Text(stringResource(R.string.shopping_summary_close))
            }
        }
    }
}
