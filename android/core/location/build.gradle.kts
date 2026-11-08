plugins {
    alias(libs.plugins.parcourses.android.library)
}

android {
    namespace = "fr.parcourses.core.location"
    testOptions.unitTests.isIncludeAndroidResources = true
}

dependencies {
    api(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.play.services.location)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
}
