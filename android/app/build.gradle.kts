plugins {
    alias(libs.plugins.parcourses.android.application)
    alias(libs.plugins.parcourses.android.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.roborazzi)
    alias(libs.plugins.androidx.baselineprofile)
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

// En `local`, l'URL par défaut vise le Supabase local vu de l'émulateur.
fun supabaseUrl(environment: String): String =
    supabaseSetting(environment, "url").ifEmpty { if (environment == "local") defaultLocalUrl else "" }

fun String.asBuildConfigString() = "\"${replace("\\", "\\\\").replace("\"", "\\\"")}\""

android {
    namespace = "fr.parcourses.app"
    defaultConfig {
        applicationId = "fr.parcourses.app"
        versionCode = 1
        versionName = "0.1.0"
    }
    buildFeatures.buildConfig = true
    // Captures Roborazzi (A11) : Robolectric a besoin des ressources fusionnées.
    testOptions.unitTests.isIncludeAndroidResources = true
    buildTypes {
        debug {
            val environment = selectedEnvironment.getOrElse("local")
            buildConfigField("String", "ENVIRONMENT", environment.asBuildConfigString())
            buildConfigField("String", "SUPABASE_URL", supabaseUrl(environment).asBuildConfigString())
            buildConfigField(
                "String",
                "SUPABASE_PUBLISHABLE_KEY",
                supabaseSetting(environment, "key").asBuildConfigString(),
            )
        }
        release {
            val environment = selectedEnvironment.getOrElse("prod")
            buildConfigField("String", "ENVIRONMENT", environment.asBuildConfigString())
            buildConfigField("String", "SUPABASE_URL", supabaseUrl(environment).asBuildConfigString())
            buildConfigField(
                "String",
                "SUPABASE_PUBLISHABLE_KEY",
                supabaseSetting(environment, "key").asBuildConfigString(),
            )
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Signé avec la clé de debug : la clé d'envoi Play n'est pas encore créée et n'entrera jamais dans le dépôt.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
    // Variantes de mesure (`benchmarkRelease`, `nonMinifiedRelease`), créées par le plugin Baseline Profile à partir
    // de `release` et jamais publiées. Avec `-Pparcourses.env=local`, elles reprennent la configuration réseau du
    // debug (HTTP vers l'hôte de l'émulateur seulement) pour vérifier la synchro de l'APK minifié contre le Supabase
    // local. Sans cette option, elles gardent celle de la release : HTTPS uniquement.
    if (selectedEnvironment.orNull == "local") {
        listOf("benchmarkRelease", "nonMinifiedRelease").forEach { name ->
            sourceSets.maybeCreate(name).res.srcDir("src/debug/res")
        }
    }
}

// Baseline Profile (A12) : généré par :baselineprofile sur un appareil, puis commité dans
// src/release/generated/baselineProfiles/. Le build ne le régénère jamais tout seul.
baselineProfile {
    automaticGenerationDuringBuild = false
    // Le profil de démarrage sert aussi à R8 pour ranger le code du lancement dans le premier fichier DEX.
    dexLayoutOptimization = true
}

dependencies {
    implementation(project(":core:designsystem"))
    implementation(project(":core:network"))
    implementation(project(":core:data"))
    implementation(project(":core:location"))
    implementation(project(":feature:lists"))
    implementation(project(":feature:storepicker"))
    implementation(project(":feature:shopping"))
    implementation(libs.androidx.work.runtime)
    implementation(libs.androidx.navigation3.runtime)
    implementation(libs.androidx.navigation3.ui)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.viewmodel.navigation3)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.core)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material.icons.core)
    // Installe le Baseline Profile à la première ouverture quand Play ne l'a pas déjà fait (installation hors Play).
    implementation(libs.androidx.profileinstaller)
    baselineProfile(project(":baselineprofile"))
    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(platform(libs.androidx.compose.bom))
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

// Captures de référence (clair, sombre, 200 %) : `./gradlew :app:recordRoborazziDebug` les réécrit,
// `:app:verifyRoborazziDebug` compare. Sans l'une de ces tâches, les tests composent l'écran sans rien écrire.
roborazzi {
    outputDir.set(file("src/test/screenshots"))
}
