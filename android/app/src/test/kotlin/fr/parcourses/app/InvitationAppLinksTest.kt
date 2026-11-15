package fr.parcourses.app

import android.app.Application
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.sqlite.driver.AndroidSQLiteDriver
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.data.sync.AccountKind
import fr.parcourses.core.database.ParcoursesDatabaseFactory
import fr.parcourses.core.designsystem.ParcoursesTheme
import fr.parcourses.core.network.InvitationLinks
import kotlinx.coroutines.Dispatchers
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/**
 * App Links des invitations (#87, lot 87.7) : hôte du build, filtre du manifeste, jeton lu dans l'intention et carte
 * de l'invitation. Un lien https sur l'hôte configuré mène au même écran que `parcourses://invitation#<jeton>`.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class InvitationAppLinksTest {
    @get:Rule
    val rule = createComposeRule()

    private val app = RuntimeEnvironment.getApplication()
    private val host = BuildConfig.INVITATION_HOST
    private val token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"

    // Conteneur créé à la demande : seuls les tests de navigation ouvrent une base.
    private val container by lazy {
        AppContainer(app, config = null) { context ->
            ParcoursesDatabaseFactory.createInMemory(context, Dispatchers.IO, AndroidSQLiteDriver())
        }
    }
    private var containerUsed = false

    @After
    fun tearDown() {
        if (containerUsed) container.database.close()
    }

    /** Intention d'un navigateur ou d'une app de messagerie qui ouvre [url]. */
    private fun view(url: String): Intent =
        Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)

    private fun resolved(url: String) =
        app.packageManager.queryIntentActivities(view(url), PackageManager.GET_RESOLVED_FILTER)

    // region Hôte du build

    @Test
    fun theDefaultHostIsTheDecidedDomain() {
        assertEquals("parcourses.hadrien.eu", host)
        val links = InvitationLinks(host)
        // « Copier le lien » : le lien https, que l'app relit comme un lien du schéma.
        assertEquals("https://parcourses.hadrien.eu/i/#$token", links.link(token))
        assertEquals(token, SharingDecisions.parseInvitationLink(links.link(token), links.httpsHost))
        assertEquals(token, SharingDecisions.parseInvitationLink("parcourses://invitation#$token", links.httpsHost))
    }

    @Test
    fun anEmptyHostKeepsOnlyTheScheme() {
        val links = InvitationLinks("")
        assertNull(links.httpsHost)
        assertEquals("parcourses://invitation#$token", links.link(token))
        assertNull(AppLinkIntents.invitationToken(view("https://$host/i/#$token"), links.httpsHost))
        assertEquals(token, AppLinkIntents.invitationToken(view("parcourses://invitation#$token"), links.httpsHost))
    }

    /**
     * Vecteur `001` rejoué par l'intention, avec l'hôte du build à la place de `parcourses.example` (casse gardée) :
     * schéma, https sur l'hôte, autre hôte, autre chemin, http et jetons invalides.
     */
    @Test
    fun vector001HoldsWithTheBuildHost() {
        val dir = File(requireNotNull(System.getProperty("parcourses.sharingVectors")) { "parcourses.sharingVectors" })
        val vector = Json.parseToJsonElement(File(dir, "001-parse-invitation-link.json").readText()).jsonObject
        val example = Regex("parcourses\\.example", RegexOption.IGNORE_CASE)
        val withHost = { text: String ->
            text.replace(example) { if (it.value == it.value.lowercase()) host else host.uppercase() }
        }
        val cases = vector.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue(cases.isNotEmpty())
        cases.forEach { case ->
            val input = case.getValue("input").jsonObject
            val url = withHost(input.getValue("url").jsonPrimitive.content)
            val httpsHost = input.optional("httpsHost")?.let(withHost)
            val expected =
                case
                    .getValue("expected")
                    .takeUnless { it is JsonNull }
                    ?.jsonPrimitive
                    ?.content
            val name = case.getValue("name").jsonPrimitive.content
            assertEquals(name, expected, AppLinkIntents.invitationToken(view(url), httpsHost))
            assertEquals(name, expected, SharingDecisions.parseInvitationLink(url, httpsHost))
        }
    }

    private fun JsonObject.optional(key: String): String? =
        get(key)?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    // endregion
    // region Manifeste

    @Test
    fun theHttpsLinkOpensTheAppWithAVerifiedFilter() {
        val matches = resolved("https://$host/i/#$token")
        assertEquals(1, matches.size)
        val activity = matches.single().activityInfo
        assertEquals(app.packageName, activity.packageName)
        assertEquals(MainActivity::class.java.name, activity.targetActivity)
        // `autoVerify` : API masquée d'IntentFilter, lue par réflexion sur l'android-all de Robolectric.
        val filter = requireNotNull(matches.single().filter)
        assertTrue(IntentFilter::class.java.getMethod("getAutoVerify").invoke(filter) as Boolean)
        assertTrue(filter.hasCategory(Intent.CATEGORY_DEFAULT))
        // Hôte sans tenir compte de la casse : le filtre l'accepte, `parseInvitationLink` aussi (vecteur 001).
        assertEquals(1, resolved("https://${host.uppercase()}/i/#$token").size)
    }

    @Test
    fun anotherHostHttpOrAnotherPathIsRefused() {
        listOf(
            "https://evil.example/i/#$token",
            "https://$host.evil.example/i/#$token",
            "http://$host/i/#$token",
            "https://$host/x/#$token",
            "https://$host/#$token",
        ).forEach { url ->
            assertTrue(url, resolved(url).isEmpty())
            assertNull(url, AppLinkIntents.invitationToken(view(url), host))
        }
    }

    @Test
    fun theSchemeLinkIsKept() {
        val matches = resolved("parcourses://invitation#$token")
        assertEquals(MainActivity::class.java.name, matches.single().activityInfo.name)
        assertEquals(token, AppLinkIntents.invitationToken(view("parcourses://invitation#$token"), host))
    }

    @Test
    fun aLinkReplayedFromRecentAppsIsNotFollowed() {
        val replayed = view("https://$host/i/#$token").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(AppLinkIntents.invitationToken(replayed, host))
        assertNull(
            AppLinkIntents.invitationToken(Intent(Intent.ACTION_MAIN, Uri.parse("https://$host/i/#$token")), host),
        )
    }

    // endregion
    // region Navigation

    /** L'intention reçue par `MainActivity`, puis la navigation : l'écran `Route.Invitation` s'ouvre sur ce jeton. */
    private fun openFromIntent(url: String) {
        val received = requireNotNull(AppLinkIntents.invitationToken(view(url), container.invitationLinks.httpsHost))
        container.offerInvitation(received)
        rule.waitUntil(5_000) { rule.onAllNodesWithTag(TAG_INVITATION_CLOSE).fetchSemanticsNodes().isNotEmpty() }
        assertEquals(token, container.pendingInvitation)
    }

    private fun showNavigation() {
        containerUsed = true
        container.accountKind.write(AccountKind.Email)
        rule.setContent { ParcoursesTheme { ParcoursesNavHost(container) } }
    }

    @Test
    fun theHttpsLinkOpensTheInvitationCard() {
        showNavigation()
        openFromIntent("https://$host/i/#$token")
    }

    @Test
    fun theSchemeLinkOpensTheSameInvitationCard() {
        showNavigation()
        openFromIntent("parcourses://invitation#$token")
        // Un second lien, https cette fois, remplace l'écran du premier : un seul écran d'invitation.
        openFromIntent("https://$host/i/#$token")
        assertEquals(1, rule.onAllNodesWithTag(TAG_INVITATION_CLOSE).fetchSemanticsNodes().size)
    }

    // endregion

    private companion object {
        /** `TAG_INVITATION_CLOSE` de `:feature:lists` (interne au module) : barre de l'écran d'une invitation. */
        const val TAG_INVITATION_CLOSE = "invitation-close"
    }
}
