import com.android.build.api.dsl.CommonExtension
import dev.detekt.gradle.extensions.DetektExtension
import org.gradle.api.Project
import org.gradle.api.artifacts.VersionCatalog
import org.gradle.api.artifacts.VersionCatalogsExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.getByType

// Valeurs communes à tous les modules (issue #10, §13).
internal object ParcoursesSdk {
    const val COMPILE = 37
    const val TARGET = 36
    const val MIN = 26
    const val JVM_TARGET = 17
}

internal val Project.libs: VersionCatalog
    get() = extensions.getByType<VersionCatalogsExtension>().named("libs")

// Configuration Android partagée par l'app et les bibliothèques.
internal fun Project.configureAndroidCommon(extension: CommonExtension) {
    extension.compileSdk = ParcoursesSdk.COMPILE
    extension.defaultConfig.minSdk = ParcoursesSdk.MIN
    extension.lint.apply {
        warningsAsErrors = false
        abortOnError = true
        checkDependencies = true
        // Catégories Accessibility et Security en erreur (#10, §12) ; baseline vide au départ.
        error += setOf("Accessibility", "Security")
        baseline = rootProject.file("config/lint/lint-baseline.xml")
    }
    configureDetekt()
}

// detekt sans résolution de types : rapide et suffisant pour les PR.
internal fun Project.configureDetekt() {
    pluginManager.apply("dev.detekt")
    extensions.configure<DetektExtension> {
        buildUponDefaultConfig.set(true)
        config.setFrom(rootProject.file("config/detekt/detekt.yml"))
    }
}
