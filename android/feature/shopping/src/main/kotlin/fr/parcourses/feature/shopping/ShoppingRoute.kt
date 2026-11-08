package fr.parcourses.feature.shopping

import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Mode courses branché sur son [ShoppingViewModel]. [onBack] quitte l'écran (la visite reste ouverte, elle expire
 * après 45 min sans coche) ; [onFinished] reçoit le résumé de la visite terminée avant que l'écran de fin ne
 * s'affiche (point d'accroche de A9) ; [onClose] ferme l'écran de fin.
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
    val reduceMotion = rememberReduceMotion()

    LaunchedEffect(viewModel) { viewModel.start() }
    // Retour au premier plan : 45 min sans coche terminent la visite.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { viewModel.foregrounded() }
    state.summary?.let { summary -> LaunchedEffect(summary) { onFinished(summary) } }
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
                onAnnouncementShown = viewModel::announcementShown,
                onClose = onClose,
                onCheckFeedback = { haptics.performHapticFeedback(HapticFeedbackType.Confirm) },
            )
        }
    ShoppingScreen(state, viewModel.input, actions, reduceMotion, modifier)
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

/**
 * « Réduire les animations » : l'échelle de durée des animations du système est à zéro (Paramètres, Accessibilité,
 * Supprimer les animations).
 */
@Composable
internal fun rememberReduceMotion(): Boolean {
    val resolver = LocalContext.current.contentResolver
    return remember(resolver) {
        Settings.Global.getFloat(resolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
}
