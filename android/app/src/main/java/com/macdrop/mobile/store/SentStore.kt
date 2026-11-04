package com.macdrop.mobile.store

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

/** 一次发送的流水记录，用于「已发送」列表 */
data class SentRecord(
    val id: String,
    val names: List<String>,
    val target: String,
    val size: Long,
    val date: Long
)

/** 发送记录只存流水，文件本身不受影响 */
object SentStore {

    private const val PREFS = "macdrop"
    private const val KEY = "sent_records"
    private const val MAX_RECORDS = 200

    fun load(context: Context): List<SentRecord> {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val names = item.optJSONArray("names")
                SentRecord(
                    id = item.optString("id").ifEmpty { UUID.randomUUID().toString() },
                    names = if (names == null) emptyList() else (0 until names.length())
                        .map { names.optString(it) },
                    target = item.optString("target"),
                    size = item.optLong("size"),
                    date = item.optLong("date")
                )
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun add(context: Context, names: List<String>, target: String, size: Long) {
        val records = load(context).toMutableList()
        records.add(
            0,
            SentRecord(
                id = UUID.randomUUID().toString(),
                names = names,
                target = target,
                size = size,
                date = System.currentTimeMillis()
            )
        )
        while (records.size > MAX_RECORDS) {
            records.removeAt(records.size - 1)
        }
        save(context, records)
    }

    fun clear(context: Context) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY).apply()
    }

    private fun save(context: Context, records: List<SentRecord>) {
        val array = JSONArray()
        for (record in records) {
            array.put(
                JSONObject().apply {
                    put("id", record.id)
                    put("names", JSONArray(record.names))
                    put("target", record.target)
                    put("size", record.size)
                    put("date", record.date)
                }
            )
        }
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, array.toString()).apply()
    }
}
