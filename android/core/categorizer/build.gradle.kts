plugins {
    alias(libs.plugins.parcourses.jvm.library)
}

dependencies {
    // Lecture du dictionnaire embarqué (API JsonElement, sans plugin ni réflexion).
    implementation(libs.kotlinx.serialization.json)
}

// Les vecteurs sont lus directement dans shared/, sans copie (#10, §5).
val categorizeVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/categorize")
val effectiveCategoryVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/effective-category")

tasks.withType<Test>().configureEach {
    inputs.dir(categorizeVectors).withPropertyName("categorizeVectors")
    systemProperty("parcourses.categorizeVectors", categorizeVectors.asFile.absolutePath)
    inputs.dir(effectiveCategoryVectors).withPropertyName("effectiveCategoryVectors")
    systemProperty("parcourses.effectiveCategoryVectors", effectiveCategoryVectors.asFile.absolutePath)
}
