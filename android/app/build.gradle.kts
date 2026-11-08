plugins {
    alias(libs.plugins.parcourses.android.application)
    alias(libs.plugins.parcourses.android.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Configuration par environnement (#10, §2.2) : `local`, `staging` ou `prod`. Rien en dur, rien de versionné.
//   -Pparcourses.env=<env>           (défaut : `local` en debug, `prod` en release)
//   parcourses.supabase.<env>.url / .key   dans ~/.gradle/gradle.properties, ou
//   PARCOURSES_SUPABASE_<ENV>_URL / _KEY   en variables d'environnement (CI).
// Seule la clé publique (publishable) est admise. Sans valeur, l'app reste entièrement locale.
// Le Supabase local est joignable depuis l'émulateur sur 10.0.2.2 ; clé : `supabase status -o env`.
val defaultLocalUrl = "http://10.0.2.2:56321"
val selectedEnvironment = providers.gradleProperty("parcourses.env")

fun supabaseSetting(
    environment: String,
    name: String,
): String =
    providers
        .gradleProperty("parcourses.supabase.$environment.$name")
        .orElse(providers.environmentVariable("PARCOURSES_SUPABASE_${environment.uppercase()}_${name.uppercase()}"))
        .orNull
        .orEmpty()

fun String.asBuildConfigString() = "\"${replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    namespace = "fr.parcourses.app"
    defaultConfig {
        applicationId = "fr.parcourses.app"
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures.buildConfig = true
    buildTypes {
        debug {
            val environment = selectedEnvironment.getOrElse("local")
            val url =
                supabaseSetting(environment, "url").ifEmpty {
                    if (environment ==
                        "local"
                    ) {
                        defaultLocalUrl
                    } else {
                        ""
                    }
                }
            buildConfigField("String", "ENVIRONMENT", environment.asBuildConfigString())
            buildConfigField("String", "SUPABASE_URL", url.asBuildConfigString())
            buildConfigField(
                "String",
                "SUPABASE_PUBLISHABLE_KEY",
                supabaseSetting(environment, "key").asBuildConfigString(),
            )
        }
        release {
            val environment = selectedEnvironment.getOrElse("prod")
            buildConfigField("String", "ENVIRONMENT", environment.asBuildConfigString())
            buildConfigField("String", "SUPABASE_URL", supabaseSetting(environment, "url").asBuildConfigString())
            buildConfigField(
                "String",
                "SUPABASE_PUBLISHABLE_KEY",
                supabaseSetting(environment, "key").asBuildConfigString(),
            )
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
    implementation(project(":core:network"))
    implementation(project(":core:data"))
    implementation(project(":feature:lists"))
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    testImplementation(libs.junit)
}
