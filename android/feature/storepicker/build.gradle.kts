plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.parcourses.android.compose)
}

android {
    namespace = "fr.parcourses.feature.storepicker"
    // Robolectric a besoin des ressources fusionnées pour les tests Compose.
    testOptions.unitTests.isIncludeAndroidResources = true
}

dependencies {
    api(project(":core:data"))
    api(project(":core:location"))
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.core)

    testImplementation(platform(libs.androidx.compose.bom))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.sqlite.framework)
    testImplementation(libs.androidx.test.core)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
