import org.gradle.api.DefaultTask
import org.gradle.api.GradleException
import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.Property
import org.gradle.api.tasks.CacheableTask
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.InputFile
import org.gradle.api.tasks.OutputFile
import org.gradle.api.tasks.PathSensitive
import org.gradle.api.tasks.PathSensitivity
import org.gradle.api.tasks.TaskAction
import org.w3c.dom.Element
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Contrôle des App Links des invitations (#87, lot 87.7) sur le manifeste **fusionné** d'une variante. Les tests
 * unitaires ne voient que le build courant ; cette tâche vérifie aussi la variante à hôte vide, lancée en CI avec
 * `-Pparcourses.invitationHost=`.
 *
 * - Hôte défini : alias `InvitationAppLinks` actif, filtre `autoVerify`, VIEW + DEFAULT + BROWSABLE, une seule
 *   donnée `https` sur [invitationHost] avec le chemin exact `/i/`.
 * - Hôte vide : alias désactivé et sans `autoVerify`.
 * - Dans les deux cas, aucun autre composant ne reçoit de lien `http`/`https`.
 */
@CacheableTask
abstract class InvitationAppLinksCheck : DefaultTask() {
    @get:InputFile
    @get:PathSensitive(PathSensitivity.NONE)
    abstract val mergedManifest: RegularFileProperty

    @get:Input
    abstract val invitationHost: Property<String>

    @get:OutputFile
    abstract val report: RegularFileProperty

    @TaskAction
    fun check() {
        val host = invitationHost.get()
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        val document = factory.newDocumentBuilder().parse(mergedManifest.get().asFile)
        val components =
            listOf("activity", "activity-alias").flatMap { tag ->
                document.getElementsByTagName(tag).let { nodes ->
                    (0 until nodes.length).map { nodes.item(it) as Element }
                }
            }
        val alias =
            components.singleOrNull { it.android("name").endsWith(".$ALIAS") }
                ?: fail("activity-alias $ALIAS absent du manifeste fusionné")
        val enabled = host.isNotEmpty()
        expect(alias.android("enabled") == enabled.toString(), "android:enabled de $ALIAS ≠ $enabled")
        val filters = alias.children("intent-filter")
        expect(filters.size == 1, "$ALIAS doit avoir un seul intent-filter")
        val filter = filters.single()
        expect(filter.android("autoVerify") == enabled.toString(), "android:autoVerify ≠ $enabled")
        expect(filter.names("action") == setOf(VIEW), "actions attendues : $VIEW")
        expect(filter.names("category") == setOf(DEFAULT, BROWSABLE), "catégories attendues : DEFAULT, BROWSABLE")
        val data = filter.children("data")
        expect(data.size == 1, "une seule balise data attendue")
        val entry = data.single()
        expect(entry.android("scheme") == "https", "schéma attendu : https")
        expect(entry.android("path") == "/i/", "chemin exact attendu : android:path=\"/i/\"")
        expect(
            listOf(
                "pathPrefix",
                "pathPattern",
                "pathAdvancedPattern",
                "pathSuffix",
            ).all { entry.android(it).isEmpty() },
            "seul android:path est admis",
        )
        if (enabled) expect(entry.android("host") == host, "hôte attendu : $host")
        // Aucun autre composant ne capte de lien web : le https passe uniquement par l'alias.
        components.filter { it !== alias }.forEach { component ->
            val web =
                component.children("intent-filter").flatMap { it.children("data") }.any {
                    it.android("scheme") in setOf("http", "https")
                }
            expect(!web, "${component.android("name")} ne doit pas recevoir de lien web")
        }
        report.get().asFile.writeText("$ALIAS enabled=$enabled host=${host.ifEmpty { "(vide)" }}\n")
    }

    private fun Element.android(name: String): String = getAttributeNS(ANDROID_NS, name)

    private fun Element.children(tag: String): List<Element> =
        (0 until childNodes.length).map { childNodes.item(it) }.filterIsInstance<Element>().filter { it.tagName == tag }

    private fun Element.names(tag: String): Set<String> = children(tag).map { it.android("name") }.toSet()

    private fun expect(
        condition: Boolean,
        message: String,
    ) {
        if (!condition) fail(message)
    }

    private fun fail(message: String): Nothing = throw GradleException("App Links des invitations : $message")

    private companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        const val ALIAS = "InvitationAppLinks"
        const val VIEW = "android.intent.action.VIEW"
        const val DEFAULT = "android.intent.category.DEFAULT"
        const val BROWSABLE = "android.intent.category.BROWSABLE"
    }
}
