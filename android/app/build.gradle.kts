plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.macdrop.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.macdrop.mobile"
        minSdk = 29
        targetSdk = 36
        versionCode = 2
        versionName = "1.5.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // 个人侧载：沿用 debug 签名，便于直接覆盖安装调试版
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}
