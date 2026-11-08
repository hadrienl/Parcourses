plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.ksp)
    alias(libs.plugins.androidx.room)
}

android {
    namespace = "fr.parcourses.core.database"
    testOptions.unitTests.isIncludeAndroidResources = true
}

// Les schémas JSON sont versionnés : ils servent aux tests de migration (#10, §3.2).
room3 {
    schemaDirectory("$projectDir/schemas")
}

dependencies {
    // Le référentiel de catégories embarqué (amorçage) vient du module JVM du classifieur.
    api(project(":core:categorizer"))
    api(libs.room.runtime)
    api(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.sqlite.bundled)
    ksp(libs.room.compiler)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.room.testing)
    testImplementation(libs.androidx.sqlite.framework)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
}
