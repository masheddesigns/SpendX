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
// Removed build directory redirection which was causing 25.0.2 error

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
