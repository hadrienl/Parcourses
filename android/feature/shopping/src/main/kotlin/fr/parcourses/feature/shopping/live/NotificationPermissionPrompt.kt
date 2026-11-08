package fr.parcourses.feature.shopping.live

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import fr.parcourses.feature.shopping.R

/**
 * Explication puis demande de `POST_NOTIFICATIONS` (API 33+), **une seule fois**, à l'entrée du premier mode
 * courses avec magasin (#10 §9). « Pas maintenant » comme un refus ne changent rien au mode courses : seule la Live
 * Update manque. [onGranted] : l'état courant est alors affiché tout de suite.
 */
@Composable
fun NotificationPermissionPrompt(
    preferences: LiveUpdatePreferences,
    onGranted: () -> Unit,
) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val context = LocalContext.current
    val granted =
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    var visible by rememberSaveable { mutableStateOf(!granted && !preferences.permissionAsked) }
    val launcher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { allowed ->
            if (allowed) onGranted()
        }
    if (!visible) return

    fun answered() {
        preferences.permissionAsked = true
        visible = false
    }
    AlertDialog(
        onDismissRequest = ::answered,
        title = { Text(stringResource(R.string.live_permission_title)) },
        text = { Text(stringResource(R.string.live_permission_text)) },
        confirmButton = {
            TextButton(onClick = {
                answered()
                launcher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }) { Text(stringResource(R.string.live_permission_allow)) }
        },
        dismissButton = {
            TextButton(onClick = ::answered) { Text(stringResource(R.string.live_permission_later)) }
        },
    )
}
