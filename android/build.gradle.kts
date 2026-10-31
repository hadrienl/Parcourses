plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.detekt) apply false
    alias(libs.plugins.spotless)
}

// Style : ktlint via Spotless sur tout le dépôt Android.
spotless {
    kotlin {
        target("**/*.kt")
        targetExclude("**/build/**")
        ktlint(libs.versions.ktlint.get())
    }
    kotlinGradle {
        target("**/*.gradle.kts")
        targetExclude("**/build/**")
        ktlint(libs.versions.ktlint.get())
    }
}

// Verrouillage des dépendances : chaque module a son gradle.lockfile.
// Mise à jour : ./gradlew resolveAndLockAll --write-locks
allprojects {
    dependencyLocking {
        lockAllConfigurations()
    }
    tasks.register("resolveAndLockAll") {
        group = "dependency locking"
        description = "Résout toutes les configurations pour écrire les gradle.lockfile."
        notCompatibleWithConfigurationCache("Résout toutes les configurations pour écrire les verrous.")
        doFirst { require(gradle.startParameter.isWriteDependencyLocks) { "Lancer avec --write-locks" } }
        doLast {
            configurations.filter { it.isCanBeResolved }.forEach { it.incoming.resolutionResult.root }
        }
    }
}
