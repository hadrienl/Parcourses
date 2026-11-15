package fr.parcourses.app

import android.content.ComponentName
import android.content.Intent
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Lien d'invitation reçu par [MainActivity] (#87, lot 87.7), dans l'application de l'app (base en mémoire, sans
 * Supabase) : lancement par l'alias des App Links, second lien par `onNewIntent`, puis recréation sans rejeu. Sans
 * Supabase, la carte montre « n'est plus valable », ce qui suffit à savoir que l'écran `Route.Invitation` est ouvert
 * sur le jeton.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = InMemoryParcoursesApp::class)
class InvitationLinkActivityTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private val app = ApplicationProvider.getApplicationContext<InMemoryParcoursesApp>()
    private val container get() = app.container
    private val host = BuildConfig.INVITATION_HOST
    private val first = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"
    private val second = "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210_-ZyXwV"

    @Before
    fun setUp() {
        // Compte e-mail : la carte s'ouvre directement, sans passer par la connexion.
        container.accountKind.write(AccountKind.Email)
    }

    /** Lien https sur l'hôte du build si le build en a un, sinon le schéma (même écran, même chemin dans l'app). */
    private fun link(token: String) =
        if (host.isNotEmpty()) "https://$host/i/#$token" else "parcourses://invitation#$token"

    /** L'intention telle que le système la remet : composant de l'alias (https) ou de l'activité (schéma). */
    private fun delivered(token: String): Intent {
        val component = if (host.isNotEmpty()) INVITATION_ALIAS else MainActivity::class.java.name
        return viewIntent(link(token)).setComponent(ComponentName(app.packageName, component))
    }

    private fun invitationScreens() = rule.onAllNodesWithTag(TAG_INVITATION_CLOSE).fetchSemanticsNodes().size

    private fun awaitInvitation(token: String) {
        rule.waitUntil(5_000) { container.pendingInvitation == token && invitationScreens() > 0 }
        rule.waitForIdle()
        // Un seul écran d'invitation : celui du dernier lien.
        assertEquals(1, invitationScreens())
    }

    @Test
    fun aLinkOpensTheInvitationThenASecondLinkReplacesItAndARecreationReplaysNothing() {
        ActivityScenario.launch<MainActivity>(delivered(first)).use { scenario ->
            awaitInvitation(first)
            // L'intention est vidée : une recréation ne retrouve pas le lien.
            scenario.onActivity { assertNull(it.intent.data) }

            // `singleTop` : le second lien arrive dans l'activité ouverte et remplace l'écran du premier.
            scenario.onActivity { activity ->
                InstrumentationRegistry.getInstrumentation().callActivityOnNewIntent(activity, delivered(second))
            }
            awaitInvitation(second)

            // Invitation fermée, puis recréation (rotation, thème) : aucun lien rejoué, aucun écran rouvert.
            rule.onNodeWithTag(TAG_INVITATION_CLOSE).performClick()
            rule.waitUntil(5_000) { invitationScreens() == 0 }
            assertNull(container.pendingInvitation)
            scenario.recreate()
            rule.waitForIdle()
            assertEquals(0, invitationScreens())
            assertNull(container.pendingInvitation)
        }
    }

    @Test
    fun aLinkReplayedFromRecentAppsOpensNoInvitation() {
        val replayed = delivered(first).addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        ActivityScenario.launch<MainActivity>(replayed).use {
            rule.waitForIdle()
            assertEquals(0, invitationScreens())
            assertNull(container.pendingInvitation)
        }
    }

    private companion object {
        /** `TAG_INVITATION_CLOSE` de `:feature:lists` (interne au module) : barre de l'écran d'une invitation. */
        const val TAG_INVITATION_CLOSE = "invitation-close"
    }
}

/** [ParcoursesApp] sans Supabase et sur une base en mémoire : le pilote SQLite embarqué n'existe pas sous Robolectric. */
class InMemoryParcoursesApp : ParcoursesApp() {
    override fun createContainer(): AppContainer =
        AppContainer(this, config = null) { context ->
            ParcoursesDatabaseFactory.createInMemory(context, Dispatchers.IO, AndroidSQLiteDriver())
        }
}
