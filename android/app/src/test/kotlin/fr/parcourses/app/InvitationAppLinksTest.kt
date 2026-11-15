package fr.parcourses.app

import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import fr.parcourses.core.data.sharing.SharingDecisions
import fr.parcourses.core.network.InvitationLinks
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/**
 * App Links des invitations (#87, lot 87.7) : liens construits avec l'hôte du build, filtre du manifeste et jeton lu
 * dans l'intention. Aucun hôte écrit en dur : tout vient de `BuildConfig.INVITATION_HOST`. Les tests du https sont
 * ignorés quand le build n'a pas d'hôte ; la variante sans hôte (alias désactivé) est vérifiée sur le manifeste
 * fusionné par `:app:check<Variante>InvitationAppLinks` (CI), et ici en désactivant l'alias.
 */
@RunWith(AndroidJUnit4::class)
@Config(application = Application::class)
class InvitationAppLinksTest {
    private val app = RuntimeEnvironment.getApplication()
    private val host = BuildConfig.INVITATION_HOST
    private val token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCde"

    private fun assumeHttpsHost() = assumeTrue("build sans hôte d'invitation", host.isNotEmpty())

    private fun resolved(url: String) =
        app.packageManager.queryIntentActivities(viewIntent(url), PackageManager.GET_RESOLVED_FILTER)

    // region Liens

    @Test
    fun copiedLinksUseTheBuildHost() {
        assumeHttpsHost()
        val links = InvitationLinks(host)
        // « Copier le lien » : le lien https, que l'app relit comme un lien du schéma.
        assertEquals("https://$host/i/#$token", links.link(token))
        assertEquals(token, SharingDecisions.parseInvitationLink(links.link(token), links.httpsHost))
        assertEquals(token, SharingDecisions.parseInvitationLink("parcourses://invitation#$token", links.httpsHost))
    }

    @Test
    fun anEmptyHostKeepsOnlyTheScheme() {
        val links = InvitationLinks("")
        assertNull(links.httpsHost)
        assertEquals("parcourses://invitation#$token", links.link(token))
        assertNull(AppLinkIntents.invitationToken(viewIntent("https://parcourses.example/i/#$token"), links.httpsHost))
        assertEquals(token, AppLinkIntents.invitationToken(viewIntent("parcourses://invitation#$token"), null))
    }

    /**
     * Vecteur `001` rejoué par l'intention, avec l'hôte du build à la place de `parcourses.example` (casse gardée) :
     * schéma, https sur l'hôte, autre hôte, autre chemin, http et jetons invalides.
     */
    @Test
    fun vector001HoldsWithTheBuildHost() {
        assumeHttpsHost()
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
            assertEquals(name, expected, AppLinkIntents.invitationToken(viewIntent(url), httpsHost))
            assertEquals(name, expected, SharingDecisions.parseInvitationLink(url, httpsHost))
        }
    }

    private fun JsonObject.optional(key: String): String? =
        get(key)?.takeUnless { it is JsonNull }?.jsonPrimitive?.content

    // endregion
    // region Manifeste

    @Test
    fun theHttpsLinkOpensTheAppWithAVerifiedFilter() {
        assumeHttpsHost()
        val matches = resolved("https://$host/i/#$token")
        assertEquals(1, matches.size)
        val activity = matches.single().activityInfo
        assertEquals(app.packageName, activity.packageName)
        assertEquals(INVITATION_ALIAS, activity.name)
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
        assumeHttpsHost()
        listOf(
            "https://evil.example/i/#$token",
            "https://$host.evil.example/i/#$token",
            "http://$host/i/#$token",
            "https://$host/x/#$token",
            "https://$host/#$token",
            // Chemin exact (`android:path`) : les fichiers de la page et les sous-chemins restent au navigateur.
            "https://$host/i/invitation.js",
            "https://$host/i/x/#$token",
            "https://$host/i#$token",
        ).forEach { url ->
            assertTrue(url, resolved(url).isEmpty())
            assertNull(url, AppLinkIntents.invitationToken(viewIntent(url), host))
        }
    }

    /**
     * Une requête ne fait pas partie du chemin pour le filtre : `/i/?utm=…#jeton` ouvre l'app, mais le vecteur `001`
     * exige `/i/` exactement, donc aucun jeton n'est lu (l'app s'ouvre sur ses listes).
     */
    @Test
    fun aQueryReachesTheAppWithoutAToken() {
        assumeHttpsHost()
        val url = "https://$host/i/?utm_source=mail#$token"
        assertEquals(1, resolved(url).size)
        assertNull(AppLinkIntents.invitationToken(viewIntent(url), host))
    }

    @Test
    fun theSchemeLinkIsKept() {
        val matches = resolved("parcourses://invitation#$token")
        assertEquals(MainActivity::class.java.name, matches.single().activityInfo.name)
        assertEquals(token, AppLinkIntents.invitationToken(viewIntent("parcourses://invitation#$token"), host))
    }

    /** Ce que produit un hôte vide (alias désactivé) : plus aucun lien https vers l'app, le schéma reste. */
    @Test
    fun aDisabledAliasCutsHttpsButKeepsTheScheme() {
        app.packageManager.setComponentEnabledSetting(
            ComponentName(app, INVITATION_ALIAS),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
        val https = if (host.isEmpty()) "https://parcourses.example/i/#$token" else "https://$host/i/#$token"
        assertTrue(resolved(https).isEmpty())
        assertEquals(1, resolved("parcourses://invitation#$token").size)
    }

    @Test
    fun aLinkReplayedFromRecentAppsIsNotFollowed() {
        val replayed = viewIntent("parcourses://invitation#$token").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(AppLinkIntents.invitationToken(replayed, host))
        val notView = Intent(Intent.ACTION_MAIN, Uri.parse("parcourses://invitation#$token"))
        assertNull(AppLinkIntents.invitationToken(notView, host))
    }

    // endregion
}

/** Alias du manifeste qui porte le filtre des App Links. */
internal const val INVITATION_ALIAS = "fr.parcourses.app.InvitationAppLinks"

/** Intention d'un navigateur ou d'une app de messagerie qui ouvre [url]. */
internal fun viewIntent(url: String): Intent =
    Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE)
