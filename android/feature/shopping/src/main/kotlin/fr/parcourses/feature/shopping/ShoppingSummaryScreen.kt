package fr.parcourses.feature.shopping

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * Écran de fin branché sur la navigation : la vibration de réussite (iOS : `sensoryFeedback(.success)`) ne part
 * qu'une fois, ni à la rotation ni au retour après la mort du processus (l'état est sauvegardé avec l'entrée).
 */
@Composable
fun ShoppingSummaryRoute(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalHapticFeedback.current
    var celebrated by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        if (!celebrated) {
            celebrated = true
            haptics.performHapticFeedback(HapticFeedbackType.Confirm)
        }
    }
    ShoppingSummaryScreen(summary, onClose, modifier)
}

/**
 * Fin des courses (#6, iOS `ShoppingSummaryView`) : « 12 articles en 18 min », puis la contribution en une phrase
 * sincère, dans un écran calme, sans badge ni série. « Retour aux listes » reste en bas, à portée du pouce.
 *
 * Accessibilité : l'écran se présente à TalkBack par son titre de volet (« Courses terminées ») ; le nombre
 * d'articles et la durée forment un seul titre ; à 200 % le contenu défile au-dessus du bouton, toujours visible.
 */
@Composable
fun ShoppingSummaryScreen(
    summary: ShoppingSummary,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pane = stringResource(R.string.shopping_summary_pane)
    val contribution = contributionText(summary)
    Scaffold(
        modifier = modifier.semantics { paneTitle = pane },
        bottomBar = {
            Button(
                onClick = onClose,
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 24.dp, vertical = 16.dp)
                        .heightIn(min = 48.dp)
                        .testTag(TAG_CLOSE),
            ) { Text(stringResource(R.string.shopping_summary_close), textAlign = TextAlign.Center) }
        },
    ) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding)) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .heightIn(min = maxHeight)
                    .padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                SummaryHeadline(summary)
                contribution?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.testTag(TAG_CONTRIBUTION),
                    )
                }
            }
        }
    }
}

/** Nombre d'articles et durée : un seul titre pour TalkBack (« 12 articles, en 18 min »). */
@Composable
private fun SummaryHeadline(summary: ShoppingSummary) {
    Column(
        Modifier.semantics(mergeDescendants = true) { heading() }.testTag(TAG_SUMMARY_HEADLINE),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            pluralStringResource(R.plurals.shopping_summary_articles, summary.checkedCount, summary.checkedCount),
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
            modifier = Modifier.testTag(TAG_SUMMARY),
        )
        Text(
            stringResource(R.string.shopping_summary_minutes, summary.minutes),
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * Ce que la visite apporte au magasin, d'après ce que l'app en savait pendant la visite (confiance de l'instantané,
 * `store_stats.confidence_q`). Rien sans magasin, ni quand aucune visite n'a été gardée ([ShoppingSummary.visitId]
 * à `null` : aucune coche, donc rien d'appris).
 */
@Composable
private fun contributionText(summary: ShoppingSummary): String? {
    val store = summary.storeName
    if (store == null || summary.visitId == null) return null
    return when (val knowledge = summary.knowledge) {
        RouteKnowledge.NoStore -> null
        RouteKnowledge.Unknown -> stringResource(R.string.shopping_summary_first, store)
        is RouteKnowledge.Learning -> stringResource(R.string.shopping_summary_known, store, knowledge.percent)
        is RouteKnowledge.Learned -> stringResource(R.string.shopping_summary_known, store, knowledge.percent)
    }
}
