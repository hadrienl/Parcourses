package fr.parcourses.app

import android.app.Application
import android.content.Intent
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.unit.dp
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.account.AccountSession
import fr.parcourses.core.data.account.AccountSignOut
import fr.parcourses.core.data.account.AccountSignOutError
import fr.parcourses.core.data.account.AccountState
import fr.parcourses.core.data.account.AccountSwitchReplay
import fr.parcourses.core.data.account.InMemoryAccountKindFlag
import fr.parcourses.core.data.account.InMemoryAccountSignOutFlag
import fr.parcourses.core.data.account.InMemoryAccountSwitchFlag
import fr.parcourses.core.data.account.LocalDataPurge
import fr.parcourses.core.data.account.ObservedAccountSwitchFlag
import fr.parcourses.core.data.account.PurgeFailure
import fr.parcourses.core.data.account.PurgeFailureCounter
import fr.parcourses.core.data.account.PurgeOperation
import fr.parcourses.core.data.account.PurgeStep
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.data.sync.InMemorySyncCursors
import fr.parcourses.core.database.CategorySeed
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.network.RemoteGateway
import fr.parcourses.core.network.StoredSessionAccount
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.uuid.Uuid

/**
 * Purges en échec (#129), sur une purge forcée en échec (référentiel des catégories illisible) : l'alerte de la
 * déconnexion et le bandeau « Changement de compte inachevé » ne changent pas aux 1ᵉʳ et 2ᵉ échecs, puis proposent de
 * libérer de l'espace et « Nous écrire » au 3ᵉ ; « Réessayer » réussi les fait disparaître. Audit d'accessibilité (cibles
 * de 48 dp, libellés, titres, régions annoncées, textes entiers) en taille par défaut et à 200 %, la plus grande police
 * des captures du projet.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class PurgeFailureUiTest {
    @get:Rule
    val rule = createComposeRule()

    private val app = RuntimeEnvironment.getApplication()
    private val text = { id: Int -> app.getString(id) }
    private val db = ParcoursesDatabaseFactory.createInMemory(app, Dispatchers.IO, AndroidSQLiteDriver())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** Référentiel des catégories illisible tant que vrai : la purge échoue à l'étape `categories`. */
    @Volatile
    private var seedFails = true
    private val kind = InMemoryAccountKindFlag().apply { write(AccountKind.Email) }
    private val cursors = InMemorySyncCursors().apply { accountId = Uuid.random() }
    private val session: AccountSession =
        AccountSession(null, kind, purgeFailures = PurgeFailureCounter { switch.isPending })
    private val switch: ObservedAccountSwitchFlag =
        ObservedAccountSwitchFlag(InMemoryAccountSwitchFlag()) { session.switchFlagCleared() }
    private val purge =
        LocalDataPurge(
            db,
            cursors,
            seed = { if (seedFails) error("disque plein") else CategorySeed.bundled() },
            accountKind = kind,
            switchFlag = switch,
        )

    private val email =
        AccountUiState(account = AccountState(AccountKind.Email, email = "lea@exemple.fr", displayName = "Léa"))

    @After
    fun tearDown() {
        scope.cancel()
        db.close()
    }

    // region Déconnexion

    private val signOutController by lazy {
        AccountSignOutController(
            AccountSignOut(
                gateway(),
                purge,
                IdleAccountDeletionHost(),
                InMemoryAccountSignOutFlag(),
                isOnline = { true },
                flush = {},
                unsent = { 0 },
                failures = session,
            ),
            scope,
        )
    }

    private fun showSignOut() {
        rule.setContent {
            ParcoursesTheme {
                val state by signOutController.state.collectAsState()
                val blocked by session.blockedPurge.collectAsState(initial = null)
                AccountSignOutOverlay(
                    state,
                    onAcknowledge = signOutController::acknowledge,
                    onRetry = { signOutController.start() },
                    blockedPurge = blocked,
                )
            }
        }
    }

    /** Attend la fin de l'essai numéro [failures] : alerte « Réessayer » affichée. */
    private fun awaitSignOutFailure(failures: Int) {
        rule.waitUntil(TIMEOUT_MS) {
            signOutController.state.value == AccountSignOutState.Failed(AccountSignOutError.Unknown) &&
                session.purgeFailureCount.value == failures
        }
        rule.waitForIdle()
    }

    private fun assertSignOutAlertBeforeThreshold() {
        rule.onNodeWithText(text(R.string.account_sign_out_failed_title)).assertIsDisplayed()
        rule
            .onNodeWithTag(TAG_SIGN_OUT_MESSAGE)
            .assert(hasText(text(R.string.account_sign_out_failed_body)))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).assert(hasText(text(R.string.account_retry))).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT).assertDoesNotExist()
        rule.onNodeWithText(text(R.string.account_sign_out_failed_blocked_body)).assertDoesNotExist()
    }

    private fun assertSignOutAlertAtThreshold() {
        rule.onNodeWithText(text(R.string.account_sign_out_failed_title)).assertIsDisplayed()
        rule
            .onNodeWithTag(TAG_SIGN_OUT_MESSAGE)
            .assert(hasText(text(R.string.account_sign_out_failed_blocked_body)))
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).assert(hasText(text(R.string.account_retry))).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT).assert(hasText(text(R.string.purge_contact))).assertIsDisplayed()
    }

    @Test
    fun theSignOutAlertChangesOnlyAtTheThirdFailureAndARetryThatSucceedsClosesIt() {
        showSignOut()
        signOutController.start()

        awaitSignOutFailure(1)
        assertSignOutAlertBeforeThreshold()
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).performClick()
        awaitSignOutFailure(2)
        assertSignOutAlertBeforeThreshold()
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).performClick()
        awaitSignOutFailure(3)
        assertSignOutAlertAtThreshold()

        // « Nous écrire » : la messagerie s'ouvre sur l'objet seul, l'alerte reste affichée au retour.
        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT).performClick()
        val intent = shadowOf(app).nextStartedActivity
        assertEquals(Intent.ACTION_SENDTO, intent.action)
        assertEquals(
            "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28purge-signout-categories%29",
            intent.dataString,
        )
        assertEquals(
            "Parcourses : purge impossible (purge-signout-categories)",
            intent.getStringExtra(Intent.EXTRA_SUBJECT),
        )
        assertNull(intent.getStringExtra(Intent.EXTRA_TEXT))
        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT_ADDRESS).assertDoesNotExist()
        assertSignOutAlertAtThreshold()

        // « Réessayer » réussi : plus d'alerte, compteur à 0.
        seedFails = false
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).performClick()
        rule.waitUntil(TIMEOUT_MS) { signOutController.state.value == AccountSignOutState.Idle }
        rule.waitForIdle()
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).assertDoesNotExist()
        rule.onNodeWithTag(TAG_SIGN_OUT_MESSAGE).assertDoesNotExist()
        assertEquals(0, session.purgeFailureCount.value)
    }

    /** Sans messagerie : le bouton reste, l'adresse s'affiche en texte sélectionnable, l'alerte reste. */
    @Test
    fun withoutAMailAppTheAlertShowsTheAddress() {
        shadowOf(app).checkActivities(true)
        showBlockedSignOut()

        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT).performClick()

        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT_ADDRESS, useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText(PurgeFailure.SUPPORT_ADDRESS).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SIGN_OUT_CONTACT).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SIGN_OUT_RETRY).assertIsDisplayed()
    }

    /** L'alerte au seuil, sans attendre trois purges : pour l'audit. */
    private fun showBlockedSignOut() {
        val failure = PurgeFailure(PurgeOperation.SignOut, PurgeStep.Store)
        rule.setContent {
            ParcoursesTheme {
                AccountSignOutOverlay(
                    AccountSignOutState.Failed(AccountSignOutError.Unknown),
                    onAcknowledge = {},
                    blockedPurge = failure,
                )
            }
        }
    }

    @Test
    fun theBlockedSignOutAlertPassesTheAccessibilityAudit() {
        showBlockedSignOut()
        assertSignOutAlertAtThreshold()
        auditAccessibility()
    }

    @Test
    @Config(fontScale = LARGEST_FONT_SCALE)
    fun theBlockedSignOutAlertPassesTheAccessibilityAuditAtTheLargestFont() {
        showBlockedSignOut()
        assertSignOutAlertAtThreshold()
        auditAccessibility()
    }

    // endregion

    // region Changement de compte

    private val replay by lazy {
        AccountSwitchReplay(gateway(), switch, cursors, kind, Mutex(), failures = session) { purge.run() }
    }

    private fun showAccount(model: AccountViewModel) {
        rule.setContent {
            ParcoursesTheme {
                val state by model.state.collectAsState()
                AccountScreen(account = state, accountActions = model.actions, onBack = {})
            }
        }
    }

    @Test
    fun theSwitchBannerAppearsAtTheThirdFailedReplayAndARetryThatSucceedsRemovesIt() {
        switch.write()
        val model =
            AccountViewModel(
                session = session,
                signOut = null,
                onSignIn = {},
                onRetrySwitch = { scope.launch { replay.run() } },
            )
        showAccount(model)

        // Lancement, puis deux retours au premier plan : rien ne change.
        repeat(2) { attempt ->
            assertFalse(runBlocking { replay.run() })
            rule.waitForIdle()
            assertEquals(attempt + 1, session.purgeFailureCount.value)
            rule.onNodeWithTag(TAG_SWITCH_BLOCKED).assertDoesNotExist()
        }
        assertFalse(runBlocking { replay.run() })
        rule.waitUntil(TIMEOUT_MS) { rule.onAllNodesWithTag(TAG_SWITCH_BLOCKED).fetchSemanticsNodes().isNotEmpty() }
        assertSwitchBanner()

        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT).performClick()
        val intent = shadowOf(app).nextStartedActivity
        assertEquals(Intent.ACTION_SENDTO, intent.action)
        assertEquals(
            "mailto:parcourses@hadrien.eu?subject=Parcourses%20%3A%20purge%20impossible%20%28purge-switch-categories%29",
            intent.dataString,
        )

        // « Réessayer » réussi : le rejeu aboutit, le bandeau disparaît.
        seedFails = false
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_RETRY).performClick()
        rule.waitUntil(TIMEOUT_MS) { rule.onAllNodesWithTag(TAG_SWITCH_BLOCKED).fetchSemanticsNodes().isEmpty() }
        assertFalse(switch.isPending)
        assertEquals(0, session.purgeFailureCount.value)
    }

    /** Un seuil franchi par la déconnexion seule n'affiche pas le bandeau : `account.switch` n'est pas posé. */
    @Test
    fun noBannerWithoutAPendingSwitch() {
        repeat(3) { session.purgeFailed(PurgeFailure(PurgeOperation.SignOut, PurgeStep.Store)) }
        showAccount(AccountViewModel(session = session, signOut = null, onSignIn = {}))
        rule.waitForIdle()
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED).assertDoesNotExist()
    }

    private fun assertSwitchBanner() {
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED).assertIsDisplayed()
        rule
            .onNodeWithText(text(R.string.account_switch_blocked_title), substring = true)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.LiveRegion))
            .assert(hasText(text(R.string.account_switch_blocked_body), substring = true))
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_RETRY).assert(hasText(text(R.string.account_retry))).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT).assert(hasText(text(R.string.purge_contact))).assertIsDisplayed()
    }

    private fun showBlockedSwitch() {
        val failure = PurgeFailure(PurgeOperation.Switch, PurgeStep.Store)
        rule.setContent {
            ParcoursesTheme { AccountScreen(account = email.copy(switchBlocked = failure), AccountActions(), {}) }
        }
    }

    @Test
    fun withoutAMailAppTheBannerShowsTheAddress() {
        shadowOf(app).checkActivities(true)
        showBlockedSwitch()

        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT).performClick()

        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT_ADDRESS, useUnmergedTree = true).assertIsDisplayed()
        rule.onNodeWithText(PurgeFailure.SUPPORT_ADDRESS).assertIsDisplayed()
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT).assertIsDisplayed()
    }

    @Test
    fun theSwitchBannerPassesTheAccessibilityAudit() {
        showBlockedSwitch()
        assertSwitchBanner()
        rule
            .onNodeWithText(text(R.string.account_switch_blocked_title), substring = true)
            .assert(SemanticsMatcher.keyIsDefined(SemanticsProperties.Heading))
        auditAccessibility()
    }

    @Test
    @Config(fontScale = LARGEST_FONT_SCALE)
    fun theSwitchBannerPassesTheAccessibilityAuditAtTheLargestFont() {
        showBlockedSwitch()
        rule.onNodeWithTag(TAG_SWITCH_BLOCKED_CONTACT).performScrollTo()
        assertSwitchBanner()
        auditAccessibility()
    }

    // endregion

    /**
     * Audit d'accessibilité : toute cible tactile (zone de toucher, marge minimale de Material comprise) fait au moins
     * 48 dp de côté et porte un libellé ; aucun texte n'est coupé en hauteur ni abrégé par une ellipse (grandes polices
     * comprises).
     */
    private fun auditAccessibility() {
        val targets = rule.onAllNodes(hasClickAction()).fetchSemanticsNodes()
        assertTrue("Aucune cible tactile", targets.isNotEmpty())
        val minimum = with(rule.density) { MIN_TOUCH_TARGET.toPx() } - TOLERANCE_PX
        for (node in targets) {
            val config = node.config
            val label =
                config.getOrNull(SemanticsProperties.Text).orEmpty().joinToString() +
                    config.getOrNull(SemanticsProperties.ContentDescription).orEmpty().joinToString()
            assertTrue("Cible sans libellé : $config", label.isNotBlank())
            // Taille de la cible, ou sa zone de toucher si Material l'agrandit (bouton d'icône de 40 dp).
            val touch = node.touchBoundsInRoot
            val width = maxOf(node.size.width.toFloat(), touch.width)
            val height = maxOf(node.size.height.toFloat(), touch.height)
            assertTrue("Cible trop petite ($width x $height px) : $label", width >= minimum && height >= minimum)
        }
        val laidOut = SemanticsMatcher.keyIsDefined(SemanticsActions.GetTextLayoutResult)
        for (node in rule.onAllNodes(laidOut, useUnmergedTree = true).fetchSemanticsNodes()) {
            val layouts = mutableListOf<TextLayoutResult>()
            node.config[SemanticsActions.GetTextLayoutResult].action?.invoke(layouts)
            for (layout in layouts) {
                val text = layout.layoutInput.text
                assertFalse("Texte coupé en hauteur : $text", layout.didOverflowHeight)
                assertTrue("Texte abrégé : $text", (0 until layout.lineCount).none(layout::isLineEllipsized))
            }
        }
    }

    /** Passerelle de la déconnexion et du rejeu : session oubliée, nouveau compte, autre compte e-mail stocké. */
    private fun gateway(): RemoteGateway {
        val other = Uuid.random()
        return java.lang.reflect.Proxy.newProxyInstance(
            RemoteGateway::class.java.classLoader,
            arrayOf(RemoteGateway::class.java),
        ) { _, method, _ ->
            when (method.name) {
                "signOut", "acknowledgeAccount" -> Unit
                "ensureSession" -> Uuid.random()
                "storedSessionAccount" -> StoredSessionAccount(other, "tom@exemple.fr")
                else -> throw UnsupportedOperationException(method.name)
            }
        } as RemoteGateway
    }

    private companion object {
        const val TIMEOUT_MS = 5_000L

        /** Police à 200 %, la plus grande des captures du projet (`*-200.png`). */
        const val LARGEST_FONT_SCALE = 2f
        val MIN_TOUCH_TARGET = 48.dp
        const val TOLERANCE_PX = 1f
    }
}
