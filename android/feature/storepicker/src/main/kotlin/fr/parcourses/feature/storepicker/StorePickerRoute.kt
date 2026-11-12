package fr.parcourses.feature.storepicker

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.text.input.rememberTextFieldState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.app.ActivityCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * Écran branché sur son [StorePickerViewModel]. La demande de localisation est lancée ici, au premier plan, quand
 * l'utilisateur l'a lue ; [onOutcome] reçoit le choix (magasin ou « sans magasin »).
 */
@Composable
fun StorePickerRoute(
    viewModel: StorePickerViewModel,
    onOutcome: (StorePickerOutcome) -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val query = rememberTextFieldState()
    val currentOutcome by rememberUpdatedState(onOutcome)

    // Lu juste avant la demande : un refus n'est définitif que si la demande était encore proposable (voir le modèle).
    var couldAskBefore by rememberSaveable { mutableStateOf(false) }
    val launcher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            viewModel.onPermissionResult(canAskAgain = context.canAskLocationAgain(), couldAskBefore = couldAskBefore)
        }

    LaunchedEffect(viewModel) { viewModel.ensureStarted() }
    LaunchedEffect(viewModel) { viewModel.outcomes.collect { currentOutcome(it) } }
    LaunchedEffect(viewModel) { snapshotFlow { query.text.toString() }.collect(viewModel::onQueryChange) }
    // Retour des réglages (ou du système) : une autorisation a pu changer.
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { viewModel.refreshAfterForeground() }

    val actions =
        remember(viewModel, launcher, context) {
            StorePickerActions(
                onBack = onBack,
                onSelect = viewModel::select,
                onRequestPermission = {
                    couldAskBefore = context.canAskLocationAgain()
                    launcher.launch(LOCATION_PERMISSIONS)
                },
                onOpenSettings = { context.openAppSettings() },
                onRetry = viewModel::start,
                onSubmitSearch = viewModel::submitSearch,
                onOpenLocationSettings = {
                    viewModel.locationSettingsOpened()
                    context.openLocationSettings()
                },
                onContinueWithoutStore = viewModel::continueWithoutStore,
                onDismissSelectionFailure = viewModel::dismissSelectionFailure,
            )
        }
    StorePickerScreen(state = state, query = query, actions = actions, modifier = modifier)
}

private val LOCATION_PERMISSIONS =
    arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)

private tailrec fun Context.findActivity(): Activity? =
    when (this) {
        is Activity -> this
        is ContextWrapper -> baseContext.findActivity()
        else -> null
    }

/**
 * `shouldShowRequestPermissionRationale` : vrai après un premier refus. Faux après « Ne plus demander » (ou un
 * deuxième refus), mais aussi avant toute demande et après un dialogue simplement fermé.
 */
private fun Context.canAskLocationAgain(): Boolean {
    val activity = findActivity() ?: return false
    return LOCATION_PERMISSIONS.any { ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }
}

/** Page des réglages de l'app. Un appareil sans cette page (#54) ne fait pas planter l'écran : la recherche reste. */
internal fun Context.openAppSettings() {
    val intent =
        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    try {
        startActivity(intent)
    } catch (ignored: ActivityNotFoundException) {
        // Rien à ouvrir.
    }
}

internal fun Context.openLocationSettings() {
    val intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    // Certains appareils n'ont pas cet écran : l'utilisateur garde la recherche par nom.
    try {
        startActivity(intent)
    } catch (ignored: ActivityNotFoundException) {
        // Rien à ouvrir.
    }
}
