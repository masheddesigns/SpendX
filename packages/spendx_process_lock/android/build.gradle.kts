plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.mashingdesigns.spend_x.process_lock"
    compileSdk = 36

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }
}


