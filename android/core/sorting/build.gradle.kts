plugins {
    alias(libs.plugins.parcourses.jvm.library)
}

dependencies {
    api(project(":core:model"))
    // Lecture des vecteurs JSON partagés, en test seulement (API JsonElement, sans plugin).
    testImplementation(libs.kotlinx.serialization.json)
}

// Les vecteurs sont lus directement dans shared/, sans copie (#10, §5).
val sortVectors = rootProject.layout.projectDirectory.dir("../shared/test-vectors/sort")

tasks.withType<Test>().configureEach {
    inputs.dir(sortVectors).withPropertyName("sortVectors")
    systemProperty("parcourses.sortVectors", sortVectors.asFile.absolutePath)
}
