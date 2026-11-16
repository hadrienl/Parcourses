plugins {
    alias(libs.plugins.parcourses.android.library)
    alias(libs.plugins.parcourses.android.compose)
}

android {
    namespace = "fr.parcourses.core.designsystem"
}

dependencies {
    // Panneau de l'article (#110) : − / + et raccourcis d'unité de `ItemQuantity`, fonctions pures.
    implementation(project(":core:categorizer"))
    implementation(libs.androidx.core.ktx)

    testImplementation(libs.junit)
}
