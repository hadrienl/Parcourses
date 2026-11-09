plugins {
    alias(libs.plugins.parcourses.android.test)
    alias(libs.plugins.androidx.baselineprofile)
}

// Génération du Baseline Profile et Macrobenchmark de l'app (A12, #10 §11). Commandes et options : android/README.md.
//   ./gradlew :app:generateBaselineProfile          réécrit app/src/release/generated/baselineProfiles/
//   ./gradlew :baselineprofile:connectedBenchmarkReleaseAndroidTest   mesure (démarrage à froid, mode courses)
// Un appareil (ou un émulateur) API 33+ doit être branché : aucun des deux ne tourne en CI de PR.
android {
    namespace = "fr.parcourses.baselineprofile"
    targetProjectPath = ":app"
    defaultConfig {
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // L'émulateur n'est pas un appareil de mesure : on l'accepte, les chiffres le signalent.
        testInstrumentationRunnerArguments["androidx.benchmark.suppressErrors"] = "EMULATOR"
    }
}

baselineProfile {
    // Appareil branché (émulateur local) plutôt qu'un Gradle Managed Device à télécharger.
    useConnectedDevices = true
}

dependencies {
    implementation(libs.androidx.test.ext.junit)
    implementation(libs.androidx.test.uiautomator)
    implementation(libs.androidx.benchmark.macro.junit4)
}
