pluginManagement {
    includeBuild("build-logic")
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Parcourses"

include(":app")
include(":core:model", ":core:sorting", ":core:categorizer")
include(":core:database", ":core:network", ":core:data", ":core:location", ":core:designsystem")
include(":feature:onboarding", ":feature:lists", ":feature:storepicker", ":feature:shopping")
