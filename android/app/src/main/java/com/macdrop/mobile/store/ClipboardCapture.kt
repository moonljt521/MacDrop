package com.macdrop.mobile.store

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import java.io.File
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 剪贴板生成的待发送文件：uri 指向本地 txt，fingerprint 用来去重 */
data class ClipboardEntry(val uri: Uri, val fingerprint: String)

/**
 * 剪贴板文本捕获：进入 App 时把剪贴板里的纯文本存成 txt，排进「待发送」队列。
 *
 * Android 10 起只有前台获得焦点的 App 能读剪贴板，本类只在 onResume 里用；
 * Android 12+ 读取时系统会弹一条「已粘贴」提示，这是系统行为，绕不开。
 */
object ClipboardCapture {

    sealed class Read {
        /** 剪贴板里没有可用的文本 */
        object Empty : Read()

        /** 有文本但读不出来 */
        object Denied : Read()

        data class Text(val text: String) : Read()
    }

    fun read(context: Context): Read {
        val manager = context.getSystemService(ClipboardManager::class.java) ?: return Read.Empty
        val clip = try {
            manager.primaryClip
        } catch (_: Exception) {
            null
        } ?: return Read.Empty
        if (clip.itemCount == 0) return Read.Empty
        // 图片、文件这类非文本剪贴板直接跳过，别把路径当成文本存进去
        val description = clip.description
        if (!description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN) &&
            !description.hasMimeType("text/*")
        ) {
            return Read.Empty
        }
        val text = try {
            clip.getItemAt(0).coerceToText(context)?.toString()
        } catch (_: Exception) {
            null
        } ?: return Read.Denied
        if (text.isBlank()) return Read.Empty
        return Read.Text(text)
    }

    /** 文本指纹：同一段文本不该被反复存成多个文件 */
    fun fingerprint(text: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    /** 剪贴板生成的临时文件放在应用私有目录，用户在文件管理器里看不到 */
    fun directory(context: Context): File =
        File(context.filesDir, "clipboard").apply { mkdirs() }

    /** 把文本写成 txt，返回文件 */
    fun writeTextFile(context: Context, text: String, prefix: String): File? {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(Date())
        val file = File(directory(context), "$prefix-$stamp.txt")
        return try {
            file.writeText(text, Charsets.UTF_8)
            file
        } catch (_: Exception) {
            null
        }
    }

    /** 清掉上次没发出去的残留文件 */
    fun cleanup(context: Context) {
        directory(context).listFiles()?.forEach { it.delete() }
    }
}

/** 剪贴板捕获的开关与去重记录 */
object ClipboardSettings {

    private const val PREFS = "macdrop_clipboard"
    private const val KEY_AUTO = "auto_capture"
    private const val KEY_HASH = "last_hash"
    private const val KEY_AT = "last_at"

    /** 同一段文本在这个时间窗内不重复捕获 */
    const val REPEAT_WINDOW_MS = 10 * 60 * 1000L

    fun isEnabled(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_AUTO, enabled).apply()
    }

    /** 上一次捕获的文本指纹与时间，用于避免同一段文本反复入队 */
    fun lastCapture(context: Context): Pair<String, Long>? {
        val prefs = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val hash = prefs.getString(KEY_HASH, null) ?: return null
        return hash to prefs.getLong(KEY_AT, 0L)
    }

    fun rememberCapture(context: Context, fingerprint: String) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HASH, fingerprint)
            .putLong(KEY_AT, System.currentTimeMillis())
            .apply()
    }

    /** 取消待发送后清掉记录，同一段文本下次还能重新捕获 */
    fun forgetCapture(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(KEY_HASH)
            .remove(KEY_AT)
            .apply()
    }
}
