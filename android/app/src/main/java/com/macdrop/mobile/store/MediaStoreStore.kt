package com.macdrop.mobile.store

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import com.macdrop.mobile.net.NetUtil
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

data class ReceivedEntry(
    val uri: Uri,
    val name: String,
    val size: Long,
    val modified: Long,
    val relativePath: String
)

/**
 * 接收文件落到系统「下载」目录，用户可在文件管理器/下载中直接看到。
 * 暂存文件放在应用 cacheDir，校验完成后再写入 MediaStore。
 */
class MediaStoreStore(context: Context) {

    private val resolver = context.applicationContext.contentResolver

    val stagingDir: File = File(context.applicationContext.cacheDir, "staging").apply {
        mkdirs()
        // 清掉上次异常退出留下的半截文件
        listFiles()?.forEach { it.delete() }
    }

    private val baseRelative = "${Environment.DIRECTORY_DOWNLOADS}/来自另一台Mac"

    fun save(
        staging: File,
        fileName: String,
        rootName: String?,
        relativePath: String?
    ): ReceivedEntry {
        var relative = "$baseRelative/"
        for (component in relativeDirectories(relativePath, rootName)) {
            relative += component + "/"
        }
        val displayName = NetUtil.sanitizeName(fileName)
        val mime = mimeType(displayName)

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val uri = resolver.insert(collection, values)
            ?: throw IOException("无法在下载目录创建文件")

        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IOException("无法写入下载目录")
            output.use { sink ->
                staging.inputStream().use { source -> source.copyTo(sink) }
            }
            val finish = ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }
            resolver.update(uri, finish, null, null)
            return ReceivedEntry(
                uri = uri,
                name = displayName,
                size = staging.length(),
                modified = System.currentTimeMillis(),
                relativePath = relative
            )
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    fun listReceived(): List<ReceivedEntry> {
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.RELATIVE_PATH
        )
        val selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
        val args = arrayOf("$baseRelative%")
        val result = mutableListOf<ReceivedEntry>()

        resolver.query(collection, projection, selection, args,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC")?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val dateIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val pathIndex = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.RELATIVE_PATH)

            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIndex)
                val uri = Uri.withAppendedPath(collection, id.toString())
                result.add(
                    ReceivedEntry(
                        uri = uri,
                        name = cursor.getString(nameIndex) ?: "file",
                        size = cursor.getLong(sizeIndex),
                        modified = TimeUnit.SECONDS.toMillis(cursor.getLong(dateIndex)),
                        relativePath = cursor.getString(pathIndex) ?: relativeBase
                    )
                )
            }
        }
        return result
    }

    fun delete(entry: ReceivedEntry) {
        resolver.delete(entry.uri, null, null)
    }

    private val relativeBase: String get() = "$baseRelative/"

    private fun relativeDirectories(path: String?, root: String?): List<String> {
        val directory = path?.substringBeforeLast('/', "") ?: ""
        val parts = directory.split('/')
            .filter { it.isNotEmpty() && it != "." && it != ".." }
            .map { NetUtil.sanitizeName(it) }
        return if (parts.isEmpty() && !root.isNullOrBlank()) {
            listOf(NetUtil.sanitizeName(root))
        } else {
            parts
        }
    }

    private fun mimeType(name: String): String {
        val extension = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            ?: "application/octet-stream"
    }
}
