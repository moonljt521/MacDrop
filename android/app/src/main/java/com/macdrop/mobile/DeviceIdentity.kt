package com.macdrop.mobile

import android.content.Context
import android.os.Build
import java.util.UUID

object DeviceIdentity {

    private const val PREFS = "macdrop"
    private const val KEY_ID = "device_id"
    private const val KEY_NAME = "device_name"

    const val MAX_NAME_LENGTH = 24

    fun id(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val saved = prefs.getString(KEY_ID, null)
        if (saved != null) return saved
        val generated = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_ID, generated).apply()
        return generated
    }

    /** 用户自定义名优先，没设置过就用机型名 */
    fun name(context: Context): String {
        val saved = customName(context)
        if (saved != null) return saved
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isEmpty()) "Android" else model
    }

    fun customName(context: Context): String? {
        val saved = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_NAME, null)
            ?.trim()
        return if (saved.isNullOrEmpty()) null else saved
    }

    /// 返回实际保存的名字；空输入则清除自定义名，回到机型名
    fun setName(context: Context, raw: String): String {
        val trimmed = raw.trim().take(MAX_NAME_LENGTH)
        val editor = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (trimmed.isEmpty()) {
            editor.remove(KEY_NAME)
        } else {
            editor.putString(KEY_NAME, trimmed)
        }
        editor.apply()
        return if (trimmed.isEmpty()) name(context) else trimmed
    }
}
