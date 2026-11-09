import com.android.build.api.dsl.TestExtension
import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.kotlin.dsl.configure

// Modules de test instrumenté séparés de l'app (:baselineprofile, A12).
class AndroidTestConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) =
        with(target) {
            pluginManager.apply("com.android.test")
            extensions.configure<TestExtension> {
                configureAndroidCommon(this)
                // Macrobenchmark et génération du Baseline Profile : API 28 au minimum (profils sans root dès 33).
                defaultConfig.minSdk = ParcoursesSdk.MIN_BENCHMARK
                defaultConfig.targetSdk = ParcoursesSdk.TARGET
            }
        }
}
