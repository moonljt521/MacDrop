package com.macdrop.mobile

import android.content.Context
import android.os.Build
import java.util.UUID

object DeviceIdentity {

    private const val PREFS = "macdrop"
    private const val KEY_ID = "device_id"

    fun id(context: Context): String {
        val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val saved = prefs.getString(KEY_ID, null)
        if (saved != null) return saved
        val generated = UUID.randomUUID().toString()
        prefs.edit().putString(KEY_ID, generated).apply()
        return generated
    }

    fun name(): String {
        val model = Build.MODEL?.trim().orEmpty()
        return if (model.isEmpty()) "Android" else model
    }
}
