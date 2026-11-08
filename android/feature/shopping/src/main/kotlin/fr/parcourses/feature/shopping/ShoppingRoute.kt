package fr.parcourses.feature.shopping

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalAccessibilityManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.time.Duration.Companion.milliseconds

/**
 * Mode courses branché sur son [ShoppingViewModel]. [onBack] quitte l'écran (la visite reste ouverte, elle expire
 * après 45 min sans coche) ; [onFinished] reçoit le résumé de la visite terminée (la navigation remplace alors cet
 * écran par celui de fin, point d'accroche de A9) ; [onClose] ferme l'écran de fin s'il est affiché ici.
 */
@Composable
fun ShoppingRoute(
    viewModel: ShoppingViewModel,
    onBack: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    onFinished: (ShoppingSummary) -> Unit = {},
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val haptics = LocalHapticFeedback.current
    val accessibility = LocalAccessibilityManager.current

    LaunchedEffect(viewModel, accessibility) {
        // « Annuler » reste affiché le temps recommandé par les réglages d'accessibilité (délai d'action allongé).
        val base = ShoppingTimings().undo.inWholeMilliseconds
        val recommended =
            accessibility?.calculateRecommendedTimeoutMillis(
                base,
                containsIcons = false,
                containsText = true,
                containsControls = true,
            ) ?: base
        viewModel.setUndoDuration(recommended.milliseconds)
        viewModel.start()
    }
    // Retour au premier plan : 45 min sans coche terminent la visite.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { viewModel.foregrounded() }
    val currentFinished by rememberUpdatedState(onFinished)
    state.summary?.let { summary -> LaunchedEffect(summary) { currentFinished(summary) } }
    KeepScreenOn(enabled = state.summary == null)

    val actions =
        remember(viewModel, haptics) {
            ShoppingActions(
                onBack = onBack,
                onToggle = viewModel::toggle,
                onNotFound = viewModel::markNotFound,
                onRestore = viewModel::restore,
                onSubmit = viewModel::submit,
                onUndo = viewModel::performUndo,
                onFinish = viewModel::finish,
                onDismissError = viewModel::dismissError,
                onScrolling = viewModel::setScrolling,
                onEditing = viewModel::setEditing,
                onSwiping = viewModel::setSwiping,
                onAnnouncementShown = viewModel::announcementShown,
                onClose = onClose,
                onCheckFeedback = { haptics.performHapticFeedback(HapticFeedbackType.Confirm) },
            )
        }
    ShoppingScreen(state, viewModel.input, actions, modifier)
}

/** L'écran reste allumé pendant les courses, et seulement alors. */
@Composable
private fun KeepScreenOn(enabled: Boolean) {
    val view = LocalView.current
    DisposableEffect(view, enabled) {
        view.keepScreenOn = enabled
        onDispose { view.keepScreenOn = false }
    }
}
