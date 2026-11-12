plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "fr.parcourses.core.network"
    // Règles R8 transmises à l'app : celles dont le code de ce module a besoin (A12).
    defaultConfig.consumerProguardFiles("consumer-rules.pro")
    testOptions.unitTests.isReturnDefaultValues = true
    // Tests instrumentés sur un vrai Keystore (#51) : `./gradlew :core:network:connectedDebugAndroidTest`.
    defaultConfig.testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
}

// Racine du dépôt : les tests de contrat lisent shared/contract et supabase/migrations.
val repositoryRoot = rootProject.projectDir.parentFile

tasks.withType<Test>().configureEach {
    systemProperty("parcourses.repoRoot", repositoryRoot.absolutePath)
    // Les migrations et le contrat sont des entrées : un changement relance le test de contrat.
    inputs
        .files(
            fileTree(repositoryRoot.resolve("supabase/migrations")),
            repositoryRoot.resolve("shared/contract/tables.json"),
        ).withPropertyName("sharedContract")
        .withPathSensitivity(PathSensitivity.RELATIVE)
}

dependencies {
    implementation(platform(libs.supabase.bom))
    implementation(libs.supabase.auth)
    implementation(libs.supabase.postgrest)
    implementation(libs.ktor.client.okhttp)
    implementation(libs.androidx.datastore)
    implementation(libs.tink.android)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.ktor.client.mock)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)

    androidTestImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.core)
}
