package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.Composable
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.RoborazziOptions
import com.github.takahirom.roborazzi.captureScreenRoboImage
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.account.PurgeFailure
import fr.parcourses.core.data.account.PurgeOperation
import fr.parcourses.core.data.account.PurgeStep
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Captures des purges en échec (#129) : l'alerte de la déconnexion au 3ᵉ échec, par-dessus l'écran Compte, et le
 * bandeau « Changement de compte inachevé ». Tout l'écran est capturé (l'alerte vit dans sa propre fenêtre). Police à
 * 200 % par la configuration (`fontScale`) : une `LocalDensity` ne passerait pas dans la fenêtre de l'alerte. Mêmes
 * tâches que [ScreenshotTest].
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w411dp-h891dp-xxhdpi", application = Application::class)
@OptIn(ExperimentalRoborazziApi::class)
class PurgeFailureScreenshotTest {
    @get:Rule
    val rule = createComposeRule()

    private val email =
        AccountUiState(
            account = AccountState(AccountKind.Email, email = "lea.martin-dubois@exemple.fr", displayName = "Léa"),
        )

    private fun capture(
        name: String,
        dark: Boolean = false,
        content: @Composable () -> Unit,
    ) {
        rule.setContent { ParcoursesTheme(darkTheme = dark) { content() } }
        rule.mainClock.advanceTimeBy(SETTLE_MS)
        rule.waitForIdle()
        captureScreenRoboImage("src/test/screenshots/$name.png", roborazziOptions = options)
    }

    @Composable
    private fun ThirdFailure() {
        AccountScreen(email, AccountActions(), {})
        AccountSignOutOverlay(
            AccountSignOutState.Failed(AccountSignOutError.Unknown),
            onAcknowledge = {},
            blockedPurge = PurgeFailure(PurgeOperation.SignOut, PurgeStep.Store),
        )
    }

    @Composable
    private fun SwitchBlocked() {
        val failure = PurgeFailure(PurgeOperation.Switch, PurgeStep.Store)
        AccountScreen(email.copy(switchBlocked = failure), AccountActions(), {})
    }

    @Test
    fun alertThirdFailureLight() = capture("purge-alert-third-failure-light") { ThirdFailure() }

    @Test
    fun alertThirdFailureDark() = capture("purge-alert-third-failure-dark", dark = true) { ThirdFailure() }

    @Test
    @Config(fontScale = 2f)
    fun alertThirdFailureLarge() = capture("purge-alert-third-failure-200") { ThirdFailure() }

    @Test
    fun switchBlockedLight() = capture("purge-switch-blocked-light") { SwitchBlocked() }

    @Test
    fun switchBlockedDark() = capture("purge-switch-blocked-dark", dark = true) { SwitchBlocked() }

    @Test
    @Config(fontScale = 2f)
    fun switchBlockedLarge() = capture("purge-switch-blocked-200") { SwitchBlocked() }

    private val options = RoborazziOptions(compareOptions = RoborazziOptions.CompareOptions(changeThreshold = 0.01f))

    private companion object {
        const val SETTLE_MS = 1_000L
    }
}
