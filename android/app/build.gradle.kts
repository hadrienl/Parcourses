import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.BuildConfigField

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

// Hôte des liens d'invitation https et des App Links (#87, lot 87.7) : `parcourses.hadrien.eu` (gradle.properties),
// surchargeable par `-Pparcourses.invitationHost=<hôte>` ou ~/.gradle/gradle.properties. Vide : ni lien https construit
// ou reconnu, ni App Link (l'alias du manifeste est désactivé, sans autoVerify) ; seul `parcourses://` reste.
val invitationHost: String =
    providers
        .gradleProperty("parcourses.invitationHost")
        .orNull
        .orEmpty()
        .trim()

// Version de l'envoi (#12) : chaque AAB envoyé sur Play doit avoir un versionCode plus grand que le précédent.
//   -Pparcourses.versionCode=<entier>   (défaut : 1)
//   -Pparcourses.versionName=<texte>    (défaut : 0.1.0)
val appVersionCode: Int =
    providers.gradleProperty("parcourses.versionCode").orNull?.trim().let { raw ->
        if (raw.isNullOrEmpty()) {
            1
        } else {
            // Plafond de Google Play : 2 100 000 000.
            raw.toIntOrNull()?.takeIf { it in 1..2_100_000_000 }
                ?: throw GradleException("parcourses.versionCode : entier de 1 à 2100000000 attendu, reçu « $raw »")
        }
    }
val appVersionName: String =
    providers
        .gradleProperty("parcourses.versionName")
        .orNull
        ?.trim()
        ?.takeIf { it.isNotEmpty() } ?: "0.1.0"

// Signature de la release par la clé d'envoi Play (#12). La clé et ses mots de passe restent hors du dépôt, dans un
// fichier de propriétés (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`, et `storeType` en option) :
//   -Pparcourses.signing=<chemin>, sinon PARCOURSES_ANDROID_SIGNING,
//   sinon ~/.config/parcourses/android-signing.properties.
// Un chemin donné explicitement doit exister. Sans chemin explicite et sans le fichier par défaut (CI, autre poste),
// la release est signée avec la clé de debug, avec un avertissement : ce paquet-là n'est pas envoyable sur Play.
// Un `storeFile` relatif se lit depuis le dossier du fichier de propriétés. Ne jamais journaliser les mots de passe.
val homeDirectory: String = providers.systemProperty("user.home").get()
val explicitSigningPath: String? =
    providers
        .gradleProperty("parcourses.signing")
        .orElse(providers.environmentVariable("PARCOURSES_ANDROID_SIGNING"))
        .orNull
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
val signingPropertiesFile: File =
    (explicitSigningPath ?: "$homeDirectory/.config/parcourses/android-signing.properties")
        .let { if (it == "~" || it.startsWith("~/")) homeDirectory + it.removePrefix("~") else it }
        .let { rootProject.file(it) }
// `fileContents` : le fichier (et son absence) devient une entrée suivie par le cache de configuration.
val signingPropertiesText: String? =
    providers.fileContents(layout.projectDirectory.file(signingPropertiesFile.absolutePath)).asText.orNull
if (signingPropertiesText == null && explicitSigningPath != null) {
    throw GradleException(
        "Fichier de signature introuvable : $signingPropertiesFile (parcourses.signing ou PARCOURSES_ANDROID_SIGNING)",
    )
}
val uploadSigning: java.util.Properties? =
    signingPropertiesText?.let { text ->
        java.util.Properties().apply { load(text.reader()) }.also { properties ->
            val missing =
                listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
                    .filter { properties.getProperty(it).isNullOrBlank() }
            if (missing.isNotEmpty()) {
                throw GradleException("Clés absentes de $signingPropertiesFile : ${missing.joinToString()}")
            }
        }
    }
if (uploadSigning == null) {
    logger.warn(
        "Parcourses : $signingPropertiesFile introuvable, la release est signée avec la clé de debug. " +
            "Ce paquet est refusé par Google Play ; voir docs/release-android.md.",
    )
}

android {
    namespace = "fr.parcourses.app"
    defaultConfig {
        applicationId = "fr.parcourses.app"
        versionCode = appVersionCode
        versionName = appVersionName
    }
    if (uploadSigning != null) {
        signingConfigs.create("upload") {
            storeFile = signingPropertiesFile.parentFile.resolve(uploadSigning.getProperty("storeFile").trim())
            storePassword = uploadSigning.getProperty("storePassword")
            keyAlias = uploadSigning.getProperty("keyAlias").trim()
            keyPassword = uploadSigning.getProperty("keyPassword")
            uploadSigning.getProperty("storeType")?.trim()?.takeIf { it.isNotEmpty() }?.let { storeType = it }
        }
    }
    buildFeatures.buildConfig = true
    defaultConfig.buildConfigField("String", "INVITATION_HOST", invitationHost.asBuildConfigString())
    // App Links (`InvitationAppLinks` dans le manifeste) : même hôte que BuildConfig, coupés quand il est vide.
    defaultConfig.manifestPlaceholders +=
        mapOf(
            "invitationHost" to invitationHost.ifEmpty { "invitation.invalid" },
            "invitationAppLinks" to invitationHost.isNotEmpty().toString(),
        )
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
            // Clé d'envoi Play quand son fichier de propriétés est présent, clé de debug sinon (voir plus haut).
            signingConfig = signingConfigs.getByName(if (uploadSigning != null) "upload" else "debug")
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

// Les variantes de mesure ne visent jamais un Supabase hébergé : elles créeraient des comptes, des listes et des
// visites factices dans le graphe partagé. Sans `-Pparcourses.env=local`, URL et clé sont vidées (app entièrement
// locale), même si la configuration de prod est présente sur la machine.
if (selectedEnvironment.orNull != "local") {
    listOf("benchmarkRelease", "nonMinifiedRelease").forEach { buildType ->
        androidComponents.onVariants(androidComponents.selector().withBuildType(buildType)) { variant ->
            listOf("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY").forEach { field ->
                variant.buildConfigFields?.put(field, BuildConfigField("String", "\"\"", null))
            }
        }
    }
}

// Le plugin Baseline Profile crée `benchmarkRelease` et `nonMinifiedRelease` dans son propre `finalizeDsl` en leur
// copiant la signature de `release`. Ce bloc, enregistré après lui, les remet sur la clé de debug : la clé d'envoi
// ne sert qu'aux paquets destinés à Play.
androidComponents.finalizeDsl { extension ->
    val debugSigning = extension.signingConfigs.getByName("debug")
    listOf("benchmarkRelease", "nonMinifiedRelease").forEach { name ->
        extension.buildTypes.findByName(name)?.signingConfig = debugSigning
    }
}

// App Links des invitations (#87, lot 87.7) contrôlés sur le manifeste fusionné de chaque variante :
// `:app:check<Variante>InvitationAppLinks`. La CI le lance avec l'hôte par défaut, puis avec `-Pparcourses.invitationHost=`.
androidComponents.onVariants { variant ->
    val name = variant.name.replaceFirstChar { it.uppercase() }
    // Lu hors du bloc : dans `register`, `invitationHost` désigne la propriété de la tâche.
    val buildHost = invitationHost
    val appLinks =
        tasks.register<InvitationAppLinksCheck>("check${name}InvitationAppLinks") {
            mergedManifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            invitationHost.set(buildHost)
            report.set(layout.buildDirectory.file("reports/invitationAppLinks/${variant.name}.txt"))
        }
    tasks.named("check") { dependsOn(appLinks) }
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
    implementation(libs.androidx.lifecycle.process)
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
    testImplementation(libs.androidx.sqlite.framework)
    testImplementation(libs.androidx.test.ext.junit)
    testImplementation(libs.androidx.compose.ui.test.junit4)
    testImplementation(libs.roborazzi)
    testImplementation(libs.roborazzi.compose)
    testImplementation(libs.roborazzi.junit.rule)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}

// Vecteur 001 du partage (#87, lot 87.7) rejoué avec l'hôte du build : lu directement dans shared/, sans copie.
val sharingVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/sharing")

tasks.withType<Test>().configureEach {
    inputs.dir(sharingVectors).withPropertyName("sharingVectors")
    systemProperty("parcourses.sharingVectors", sharingVectors.asFile.absolutePath)
}

// Captures de référence (clair, sombre, 200 %) : `./gradlew :app:recordRoborazziDebug` les réécrit,
// `:app:verifyRoborazziDebug` compare. Sans l'une de ces tâches, les tests composent l'écran sans rien écrire.
roborazzi {
    outputDir.set(file("src/test/screenshots"))
}
