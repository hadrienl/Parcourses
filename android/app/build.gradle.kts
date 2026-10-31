plugins {
    alias(libs.plugins.parcourses.android.application)
    alias(libs.plugins.parcourses.android.compose)
}

android {
    namespace = "fr.parcourses.app"
    defaultConfig {
        applicationId = "fr.parcourses.app"
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures.buildConfig = true
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signé avec la clé de debug tant que la signature Play n'existe pas (A12).
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    implementation(project(":core:designsystem"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
