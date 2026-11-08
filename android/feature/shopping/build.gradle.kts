plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.parcourses.android.compose)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "fr.parcourses.feature.shopping"
    // Robolectric a besoin des ressources fusionnées pour les tests Compose.
    testOptions.unitTests.isIncludeAndroidResources = true
    // Robolectric sous Android 16 (tests de `ProgressStyle`) lit la mémoire partagée par un accès interne au JDK.
    testOptions.unitTests.all { it.jvmArgs("--add-exports=java.base/jdk.internal.access=ALL-UNNAMED") }
}

dependencies {
    api(project(":core:data"))
    api(project(":core:model"))
    implementation(project(":core:sorting"))
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.compose.material.icons.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.kotlinx.serialization.json)

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
