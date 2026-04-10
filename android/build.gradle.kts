plugins {
    id("com.android.application") apply false
    id("org.jetbrains.kotlin.android") apply false
    id("com.google.gms.google-services") version "4.3.15" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

subprojects {
    val dartBuildDir = layout.settingsDirectory.dir("../build/${project.name}")
    project.buildDir = dartBuildDir.asFile
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}