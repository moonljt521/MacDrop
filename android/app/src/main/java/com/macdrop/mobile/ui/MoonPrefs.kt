package com.macdrop.mobile.ui

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * 轻量界面偏好：语言与外观。
 *
 * 与 GallerySettings 一样只落一份 SharedPreferences；不引入 AndroidX，
 * 语言/外观都靠 [wrap] 覆盖 Configuration，再由 Activity 重建生效。
 */
object MoonPrefs {

    const val LANGUAGE_ZH = "zh"
    const val LANGUAGE_EN = "en"

    const val APPEARANCE_SYSTEM = "system"
    const val APPEARANCE_LIGHT = "light"
    const val APPEARANCE_DARK = "dark"

    private const val PREFS = "moon_ui_prefs"
    private const val KEY_LANGUAGE = "language"
    private const val KEY_APPEARANCE = "appearance"

    private var appContext: Context? = null
    private var languageValue = LANGUAGE_ZH
    private var appearanceValue = APPEARANCE_SYSTEM

    /** Activity / Service 启动时先读一次，之后的读写都在内存里 */
    fun init(context: Context) {
        val app = context.applicationContext
        appContext = app
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        languageValue = prefs.getString(KEY_LANGUAGE, LANGUAGE_ZH)
            ?.takeIf { it == LANGUAGE_ZH || it == LANGUAGE_EN } ?: LANGUAGE_ZH
        appearanceValue = prefs.getString(KEY_APPEARANCE, APPEARANCE_SYSTEM)
            ?.takeIf { it == APPEARANCE_SYSTEM || it == APPEARANCE_LIGHT || it == APPEARANCE_DARK }
            ?: APPEARANCE_SYSTEM
    }

    val language: String get() = languageValue

    val appearance: String get() = appearanceValue

    fun setLanguage(value: String) {
        if (value != LANGUAGE_ZH && value != LANGUAGE_EN) return
        languageValue = value
        persist(KEY_LANGUAGE, value)
    }

    fun setAppearance(value: String) {
        if (value != APPEARANCE_SYSTEM && value != APPEARANCE_LIGHT && value != APPEARANCE_DARK) return
        appearanceValue = value
        persist(KEY_APPEARANCE, value)
    }

    private fun persist(key: String, value: String) {
        val app = appContext ?: return
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(key, value).apply()
    }

    fun localeFor(language: String): Locale = if (language == LANGUAGE_EN) {
        Locale.ENGLISH
    } else {
        Locale.forLanguageTag("zh-Hans")
    }

    /**
     * 把语言/外观叠加到 base 的 Configuration 上。
     * 系统外观 + 中文时没有任何覆盖，直接返回原 Context，避免多余的资源副本。
     */
    fun wrap(base: Context): Context {
        if (languageValue == LANGUAGE_ZH && appearanceValue == APPEARANCE_SYSTEM) return base
        val app = appContext ?: base.applicationContext
        val config = Configuration(app.resources.configuration)
        val locale = localeFor(languageValue)
        config.setLocale(locale)
        config.setLayoutDirection(locale)
        when (appearanceValue) {
            APPEARANCE_DARK -> config.uiMode =
                (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    Configuration.UI_MODE_NIGHT_YES
            APPEARANCE_LIGHT -> config.uiMode =
                (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    Configuration.UI_MODE_NIGHT_NO
        }
        return app.createConfigurationContext(config)
    }
}
