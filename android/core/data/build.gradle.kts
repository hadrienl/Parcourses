plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "fr.parcourses.core.data"
    testOptions.unitTests.isIncludeAndroidResources = true
}

// Vecteurs de synchro partagés avec iOS (#87), lus directement dans shared/, sans copie.
val syncVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/sync")

// Vecteurs du partage (#87, lots 87.4 et 87.6), même règle.
val sharingVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/sharing")

tasks.withType<Test>().configureEach {
    inputs.dir(syncVectors).withPropertyName("syncVectors")
    systemProperty("parcourses.syncVectors", syncVectors.asFile.absolutePath)
    inputs.dir(sharingVectors).withPropertyName("sharingVectors")
    systemProperty("parcourses.sharingVectors", sharingVectors.asFile.absolutePath)
}

dependencies {
    api(project(":core:database"))
    api(project(":core:network"))
    api(project(":core:categorizer"))
    api(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.work.runtime)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.androidx.sqlite.framework)
    testImplementation(libs.androidx.work.testing)
}
