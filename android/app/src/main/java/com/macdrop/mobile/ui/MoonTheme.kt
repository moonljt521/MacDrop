package com.macdrop.mobile.ui

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.widget.TextView

class MoonUi(val context: Context) {

    private val resources = context.applicationContext.resources

    val isDark: Boolean =
        (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    val colors: MoonColors = if (isDark) MoonColors.dark() else MoonColors.light()

    private val density = resources.displayMetrics.density

    fun dp(value: Int): Int = (value * density).toInt()

    fun dpf(value: Float): Float = value * density

    val regular: Typeface = Typeface.create("sans-serif", Typeface.NORMAL)
    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    val semibold: Typeface = Typeface.create(regular, 600, false)
    val bold: Typeface = Typeface.create("sans-serif", Typeface.BOLD)

    fun alpha(color: Int, alpha: Float): Int = Color.argb(
        (alpha * 255f).toInt().coerceIn(0, 255),
        Color.red(color),
        Color.green(color),
        Color.blue(color)
    )

    val radiusPanel = 22
    val radiusControl = 14
    val radiusTile = 12
    val radiusSmall = 10
}

object MoonType {
    const val TOPBAR = 32f
    const val HERO = 17f
    const val SECTION = 20f
    const val TITLE = 17f
    const val BODY = 16f
    const val META = 13f
    const val LABEL = 12f
    const val NUMERIC = 28f
    const val BUTTON = 16f
}

object MoonTrack {
    const val TIGHT = -0.02f
    const val HERO = -0.02f
    const val NORMAL = 0f
    const val WIDE = 0f
}

/**
 * 给 [TextView] 加字距。
 */
fun TextView.tracked(ems: Float): TextView = apply {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
        letterSpacing = ems
    }
}

data class MoonColors(
    val canvas: Int,
    val surface: Int,
    val surfaceMuted: Int,
    val textPrimary: Int,
    val textSecondary: Int,
    val textTertiary: Int,
    val divider: Int,
    val primary: Int,
    val primaryStrong: Int,
    val primaryTint: Int,
    val onPrimary: Int,
    val ink: Int,
    val onInk: Int,
    val success: Int,
    val successText: Int,
    val successTint: Int,
    val warning: Int,
    val warningText: Int,
    val warningTint: Int,
    val danger: Int,
    val dangerText: Int,
    val dangerTint: Int
) {
    companion object {
        fun light() = MoonColors(
            canvas = Color.parseColor("#F7F8FB"),
            surface = Color.parseColor("#FFFFFF"),
            surfaceMuted = Color.parseColor("#EDF1FB"),
            textPrimary = Color.parseColor("#202B40"),
            textSecondary = Color.parseColor("#687284"),
            textTertiary = Color.parseColor("#687284"),
            divider = Color.parseColor("#E2E7F0"),
            primary = Color.parseColor("#3E5BCA"),
            primaryStrong = Color.parseColor("#3E5BCA"),
            primaryTint = Color.parseColor("#EDF1FB"),
            onPrimary = Color.parseColor("#FFFFFF"),
            ink = Color.parseColor("#233149"),
            onInk = Color.parseColor("#FFFFFF"),
            success = Color.parseColor("#227B65"),
            successText = Color.parseColor("#227B65"),
            successTint = Color.parseColor("#E7F8F0"),
            warning = Color.parseColor("#F79009"),
            warningText = Color.parseColor("#B54708"),
            warningTint = Color.parseColor("#FFF4E5"),
            danger = Color.parseColor("#EF4444"),
            dangerText = Color.parseColor("#B42318"),
            dangerTint = Color.parseColor("#FEF3F2")
        )

        fun dark() = MoonColors(
            canvas = Color.parseColor("#11141C"),
            surface = Color.parseColor("#202631"),
            surfaceMuted = Color.parseColor("#242E47"),
            textPrimary = Color.parseColor("#EDF1FB"),
            textSecondary = Color.parseColor("#A7B1C4"),
            textTertiary = Color.parseColor("#A7B1C4"),
            divider = Color.parseColor("#303B50"),
            primary = Color.parseColor("#A9BBFF"),
            primaryStrong = Color.parseColor("#A9BBFF"),
            primaryTint = Color.parseColor("#242E47"),
            onPrimary = Color.parseColor("#1B2740"),
            ink = Color.parseColor("#DCE5FA"),
            onInk = Color.parseColor("#1B2740"),
            success = Color.parseColor("#7DD4B6"),
            successText = Color.parseColor("#7DD4B6"),
            successTint = Color.parseColor("#102A20"),
            warning = Color.parseColor("#FDB022"),
            warningText = Color.parseColor("#FEC84B"),
            warningTint = Color.parseColor("#2A210F"),
            danger = Color.parseColor("#F97066"),
            dangerText = Color.parseColor("#FDA29B"),
            dangerTint = Color.parseColor("#2A1512")
        )
    }
}
