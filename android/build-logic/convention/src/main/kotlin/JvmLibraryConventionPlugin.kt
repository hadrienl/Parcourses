import org.gradle.api.Plugin
import org.gradle.api.Project
import org.gradle.api.plugins.JavaPluginExtension
import org.gradle.kotlin.dsl.configure
import org.gradle.kotlin.dsl.dependencies
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension

// Modules Kotlin purs, sans aucune dépendance Android (:core:model, :core:sorting…).
class JvmLibraryConventionPlugin : Plugin<Project> {
    override fun apply(target: Project) =
        with(target) {
            pluginManager.apply("org.jetbrains.kotlin.jvm")
            extensions.configure<KotlinJvmProjectExtension> {
                compilerOptions.jvmTarget.set(JvmTarget.fromTarget(ParcoursesSdk.JVM_TARGET.toString()))
            }
            extensions.configure<JavaPluginExtension> {
                sourceCompatibility =
                    org.gradle.api.JavaVersion
                        .toVersion(ParcoursesSdk.JVM_TARGET)
                targetCompatibility =
                    org.gradle.api.JavaVersion
                        .toVersion(ParcoursesSdk.JVM_TARGET)
            }
            dependencies {
                add("testImplementation", libs.findLibrary("junit").get())
            }
            // Alias pour que la CI lance la même tâche sur tous les modules.
            tasks.register("testDebugUnitTest") { dependsOn("test") }
            configureDetekt()
        }
}
