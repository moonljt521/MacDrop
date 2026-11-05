package com.macdrop.mobile.ui

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface

/**
 * MoonDrop 移动端设计令牌，来源见仓库根目录 DESIGN.md。
 * 浅色是默认主题，深色按系统外观自动切换；这里不提供应用内开关。
 */
class MoonUi(val context: Context) {

    private val resources = context.applicationContext.resources

    val isDark: Boolean =
        (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) ==
            Configuration.UI_MODE_NIGHT_YES

    val colors: MoonColors = if (isDark) MoonColors.dark() else MoonColors.light()

    private val density = resources.displayMetrics.density

    fun dp(value: Int): Int = (value * density).toInt()

    fun dpf(value: Float): Float = value * density

    val medium: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    val bold: Typeface = Typeface.create("sans-serif", Typeface.BOLD)

    fun alpha(color: Int, alpha: Float): Int = Color.argb(
        (alpha * 255f).toInt().coerceIn(0, 255),
        Color.red(color),
        Color.green(color),
        Color.blue(color)
    )
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
            canvas = Color.parseColor("#F7F9FC"),
            surface = Color.parseColor("#FFFFFF"),
            surfaceMuted = Color.parseColor("#F1F5F9"),
            textPrimary = Color.parseColor("#0F172A"),
            textSecondary = Color.parseColor("#64748B"),
            textTertiary = Color.parseColor("#94A3B8"),
            divider = Color.parseColor("#EDF1F6"),
            primary = Color.parseColor("#2C6BFF"),
            primaryStrong = Color.parseColor("#1E56D6"),
            primaryTint = Color.parseColor("#EAF0FF"),
            onPrimary = Color.parseColor("#FFFFFF"),
            success = Color.parseColor("#12B76A"),
            successText = Color.parseColor("#067647"),
            successTint = Color.parseColor("#E7F8F0"),
            warning = Color.parseColor("#F79009"),
            warningText = Color.parseColor("#B54708"),
            warningTint = Color.parseColor("#FFF4E5"),
            danger = Color.parseColor("#EF4444"),
            dangerText = Color.parseColor("#B42318"),
            dangerTint = Color.parseColor("#FEF3F2")
        )

        fun dark() = MoonColors(
            canvas = Color.parseColor("#0B0F14"),
            surface = Color.parseColor("#141A22"),
            surfaceMuted = Color.parseColor("#1B232D"),
            textPrimary = Color.parseColor("#E8EDF5"),
            textSecondary = Color.parseColor("#9AA7B8"),
            textTertiary = Color.parseColor("#6B7A8C"),
            divider = Color.parseColor("#242D39"),
            primary = Color.parseColor("#6E9BFF"),
            primaryStrong = Color.parseColor("#A8C3FF"),
            primaryTint = Color.parseColor("#1A2740"),
            onPrimary = Color.parseColor("#06122B"),
            success = Color.parseColor("#3DD68C"),
            successText = Color.parseColor("#6EE7B7"),
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
