package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountDeletionError
import fr.parcourses.core.designsystem.ParcoursesTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/** Messages de la suppression (#68) : doute (C5, C6), « Réessayez dans un instant. » (C2), appareil seul (C3). */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class AccountDeletionOverlayTest {
    @get:Rule
    val rule = createComposeRule()

    private val text = { id: Int -> RuntimeEnvironment.getApplication().getString(id) }
    private val calls = mutableListOf<String>()
    private var state: AccountDeletionState by mutableStateOf(AccountDeletionState.Idle)

    private fun show(
        initial: AccountDeletionState,
        localOnly: Boolean = false,
    ) {
        state = initial
        rule.setContent {
            ParcoursesTheme {
                AccountDeletionOverlay(
                    state,
                    AccountDeletionOverlayActions(
                        onAcknowledge = { calls += "acknowledge" },
                        onRetry = { calls += "retry" },
                        onCancel = { calls += "cancel" },
                    ),
                    localOnly = localOnly,
                )
            }
        }
    }

    @Test
    fun theDoubtOffersOnlyRetryAndCancel() {
        show(AccountDeletionState.Failed(AccountDeletionError.Unknown))

        rule.onNodeWithText(text(R.string.about_account_unconfirmed_title)).assertIsDisplayed()
        rule
            .onNodeWithTag(TAG_ACCOUNT_MESSAGE)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        rule.onNodeWithText(text(R.string.about_account_unconfirmed_body)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.about_account_retry_soon)).assertDoesNotExist()
        rule.onNodeWithTag(TAG_ACCOUNT_OK).assertDoesNotExist()

        rule.onNodeWithTag(TAG_ACCOUNT_RETRY).assert(hasText(text(R.string.about_account_retry))).performClick()
        rule
            .onNodeWithTag(TAG_ACCOUNT_UNCONFIRMED_CANCEL)
            .assert(hasText(text(R.string.about_account_cancel)))
            .performClick()

        assertEquals(listOf("retry", "cancel"), calls)
    }

    @Test
    fun cancellingTooSoonAsksToRetryInAMoment() {
        show(AccountDeletionState.Failed(AccountDeletionError.Unknown, retrySoon = true))

        rule.onNodeWithText(text(R.string.about_account_retry_soon)).assertIsDisplayed()
        rule.onNodeWithTag(TAG_ACCOUNT_RETRY).assertIsDisplayed()
    }

    @Test
    fun withoutServerTheDoubtSaysNothingAboutServers() {
        show(AccountDeletionState.Failed(AccountDeletionError.Unknown), localOnly = true)

        rule.onNodeWithText(text(R.string.about_account_unconfirmed_body_local)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.about_account_unconfirmed_body)).assertDoesNotExist()
    }

    @Test
    fun aDeletionOnTheDeviceAloneSaysWhatHappensOnTheServers() {
        show(AccountDeletionState.DoneLocally)

        rule.onNodeWithText(text(R.string.about_account_done_local_title)).assertIsDisplayed()
        rule.onNodeWithText(text(R.string.about_account_done_local_body)).assertIsDisplayed()
        rule.onNodeWithTag(TAG_ACCOUNT_OK).performClick()

        assertEquals(listOf("acknowledge"), calls)
    }

    @Test
    fun offlineAndRefusalAreClosedWithOk() {
        show(AccountDeletionState.Failed(AccountDeletionError.Offline))
        rule.onNodeWithText(text(R.string.about_account_offline)).assertIsDisplayed()

        state = AccountDeletionState.Failed(AccountDeletionError.Refused)
        rule.onNodeWithText(text(R.string.about_account_refused)).assertIsDisplayed()
        rule.onNodeWithTag(TAG_ACCOUNT_OK).performClick()

        assertEquals(listOf("acknowledge"), calls)
    }
}
