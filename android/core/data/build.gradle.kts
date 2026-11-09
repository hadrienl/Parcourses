plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "fr.parcourses.core.data"
    // Règles R8 transmises à l'app : celles dont le code de ce module a besoin (A12).
    defaultConfig.consumerProguardFiles("consumer-rules.pro")
    testOptions.unitTests.isIncludeAndroidResources = true
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
