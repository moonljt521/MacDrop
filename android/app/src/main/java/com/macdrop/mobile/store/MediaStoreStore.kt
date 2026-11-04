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

/** 相册保存的开关与判定，接收服务和界面共用同一份偏好 */
object GallerySettings {

    private const val PREFS = "macdrop"
    private const val KEY_AUTO = "auto_save_gallery"

    fun isEnabled(context: Context): Boolean =
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO, true)

    fun setEnabled(context: Context, enabled: Boolean) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_AUTO, enabled).apply()
    }

    fun isMedia(name: String): Boolean {
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(
            name.substringAfterLast('.', "").lowercase()
        ) ?: return false
        return mime.startsWith("image/") || mime.startsWith("video/")
    }
}

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

    /**
     * 把已收到的图片/视频再复制一份到系统相册目录（Pictures/MoonDrop、Movies/MoonDrop）。
     * 「下载」里的原件不动。
     */
    fun saveToGallery(entry: ReceivedEntry): Uri {
        val mime = mimeType(entry.name)
        val collection = when {
            mime.startsWith("image/") ->
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            mime.startsWith("video/") ->
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> throw IOException("只有图片和视频能存入相册")
        }
        val directory = if (mime.startsWith("image/")) {
            "${Environment.DIRECTORY_PICTURES}/MoonDrop"
        } else {
            "${Environment.DIRECTORY_MOVIES}/MoonDrop"
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, entry.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, directory)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("无法在相册目录创建文件")
        try {
            val source = resolver.openInputStream(entry.uri)
                ?: throw IOException("无法读取已收到的文件")
            val sink = resolver.openOutputStream(uri)
                ?: throw IOException("无法写入相册目录")
            source.use { input -> sink.use { output -> input.copyTo(output) } }
            resolver.update(uri, ContentValues().apply {
                put(MediaStore.MediaColumns.IS_PENDING, 0)
            }, null, null)
            return uri
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    fun listReceived(): List<ReceivedEntry> {        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
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

    /**
     * 清空已接收：删除「下载/来自另一台Mac」下的全部条目。
     * 相册里的副本不动——那是用户自己的照片。
     */
    fun clearReceived() {
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        resolver.delete(
            collection,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
            arrayOf("$baseRelative%")
        )
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
