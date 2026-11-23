import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 正式签名：keystore 与口令放在本地 keystore.properties（不入库），
// 证书沿用 1.6.0 及更早的发布包，已装设备可以直接覆盖升级。
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.macdrop.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.macdrop.mobile"
        minSdk = 29
        targetSdk = 36
        versionCode = 4
        versionName = "1.6.1"
    }

    signingConfigs {
        create("release") {
            check(keystorePropsFile.exists()) {
                "缺少 $keystorePropsFile：发布构建需要正式签名，请按 README 的说明创建 keystore.properties"
            }
            storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
            storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias")
            keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        debug {
            // 调试包也用正式签名，避免同一台设备上签名的两份包互相覆盖失败
            signingConfig = signingConfigs.getByName("release")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("release")
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
