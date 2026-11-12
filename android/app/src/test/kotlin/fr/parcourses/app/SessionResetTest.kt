package fr.parcourses.app

import android.app.Application
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.network.RemoteError
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/** « Réinitialiser la session » (#51) : visibilité, confirmation, résultat. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class SessionResetTest {
    @get:Rule
    val rule = createComposeRule()

    @Before
    fun setUp() = Dispatchers.setMain(Dispatchers.Unconfined)

    @After
    fun tearDown() = Dispatchers.resetMain()

    private val stuck = MutableStateFlow(false)
    private var resets = 0
    private var outcome: CompletableDeferred<Unit>? = null

    private fun model() =
        SessionResetViewModel(stuck) {
            resets++
            outcome?.await()
            true
        }

    @Test
    fun theSectionOnlyShowsWhileTheStorageIsStuck() {
        val model = model()
        assertFalse(model.state.value.visible)
        stuck.value = true
        assertTrue(model.state.value.visible)
        stuck.value = false
        assertFalse(model.state.value.visible)
    }

    @Test
    fun nothingIsResetWithoutConfirmation() {
        stuck.value = true
        val model = model()
        model.actions.onRequest()
        assertEquals(SessionResetPhase.Confirming, model.state.value.phase)
        model.actions.onDismiss()
        assertEquals(SessionResetPhase.Idle, model.state.value.phase)
        assertEquals(0, resets)
    }

    @Test
    fun aConfirmedResetRunsOnceAndStaysShownOnceDone() {
        stuck.value = true
        outcome = CompletableDeferred()
        val model = model()
        model.actions.onRequest()
        model.actions.onConfirm()
        model.actions.onConfirm()
        assertEquals(SessionResetPhase.Running, model.state.value.phase)
        // Le stockage se relit : la section reste, avec son résultat.
        stuck.value = false
        outcome!!.complete(Unit)
        assertEquals(1, resets)
        assertEquals(SessionResetUiState(visible = true, phase = SessionResetPhase.Done), model.state.value)
    }

    @Test
    fun aRefusedResetCanBeRetried() {
        stuck.value = true
        val model = SessionResetViewModel(stuck) { throw RemoteError.SecureStorageLocked(IllegalStateException()) }
        model.actions.onRequest()
        model.actions.onConfirm()
        assertEquals(SessionResetPhase.Failed, model.state.value.phase)
        model.actions.onRequest()
        assertEquals(SessionResetPhase.Confirming, model.state.value.phase)
    }

    @Test
    fun theAboutScreenAsksBeforeResetting() {
        stuck.value = true
        val model = model()
        rule.setContent {
            ParcoursesTheme {
                val state = model.state.collectAsState().value
                AboutScreen("1.0 (1)", {}, sessionReset = state, sessionResetActions = model.actions)
            }
        }
        rule.onNodeWithText("Session", ignoreCase = true).assertExists()
        rule.onNodeWithTag(TAG_SESSION_RESET).performClick()
        rule.onNodeWithText("Réinitialiser la session ?").assertExists()
        rule.onNodeWithTag(TAG_SESSION_RESET_CONFIRM).performClick()
        rule.waitForIdle()
        assertEquals(1, resets)
        rule.onNodeWithText("Session réinitialisée", substring = true).assertExists()
        rule.onNodeWithTag(TAG_SESSION_RESET).assertDoesNotExist()
    }

    @Test
    fun theButtonIsDisabledWhileResetting() {
        stuck.value = true
        outcome = CompletableDeferred()
        val model = model()
        model.actions.onRequest()
        model.actions.onConfirm()
        rule.setContent {
            ParcoursesTheme {
                AboutScreen(
                    "1.0 (1)",
                    {},
                    sessionReset = model.state.collectAsState().value,
                    sessionResetActions = model.actions,
                )
            }
        }
        rule.onNodeWithTag(TAG_SESSION_RESET).assertIsNotEnabled()
        outcome!!.complete(Unit)
    }

    @Test
    fun aKeyThatOpensAgainLeavesNothingToReset() {
        stuck.value = true
        val model = SessionResetViewModel(stuck) { false }
        model.actions.onRequest()
        model.actions.onConfirm()
        stuck.value = false
        assertEquals(SessionResetUiState(visible = false, phase = SessionResetPhase.Idle), model.state.value)
    }

    @Test
    fun aFailureIsNoLongerShownOnceTheStorageReadsAgain() {
        stuck.value = true
        val model = SessionResetViewModel(stuck) { throw RemoteError.SecureStorageLocked(IllegalStateException()) }
        model.actions.onRequest()
        model.actions.onConfirm()
        assertTrue(model.state.value.visible)
        stuck.value = false
        assertFalse(model.state.value.visible)
    }

    @Test
    fun noSessionSectionByDefault() {
        rule.setContent { ParcoursesTheme { AboutScreen("1.0 (1)", {}) } }
        rule.onNodeWithText("Session", ignoreCase = true).assertDoesNotExist()
    }
}
