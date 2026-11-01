plugins {
    alias(libs.plugins.parcourses.jvm.library)
}

dependencies {
    // Lecture du dictionnaire embarqué (API JsonElement, sans plugin ni réflexion).
    implementation(libs.kotlinx.serialization.json)
}

// Les vecteurs sont lus directement dans shared/, sans copie (#10, §5).
val categorizeVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/categorize")

tasks.withType<Test>().configureEach {
    inputs.dir(categorizeVectors).withPropertyName("categorizeVectors")
    systemProperty("parcourses.categorizeVectors", categorizeVectors.asFile.absolutePath)
}
