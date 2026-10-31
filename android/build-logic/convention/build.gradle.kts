plugins {
    `kotlin-dsl`
}

dependencies {
    compileOnly(libs.android.gradlePlugin)
    compileOnly(libs.kotlin.gradlePlugin)
    compileOnly(libs.compose.gradlePlugin)
    implementation("dev.detekt:detekt-gradle-plugin:${libs.versions.detekt.get()}")
}

gradlePlugin {
    plugins {
        register("androidApplication") {
            id = "parcourses.android.application"
            implementationClass = "AndroidApplicationConventionPlugin"
        }
        register("androidLibrary") {
            id = "parcourses.android.library"
            implementationClass = "AndroidLibraryConventionPlugin"
        }
        register("androidCompose") {
            id = "parcourses.android.compose"
            implementationClass = "AndroidComposeConventionPlugin"
        }
        register("jvmLibrary") {
            id = "parcourses.jvm.library"
            implementationClass = "JvmLibraryConventionPlugin"
        }
    }
}
