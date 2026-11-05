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
    private const val KEY_GALLERY_CLEARED_AT = "gallery_cleared_at_seconds"

    /** 收到的文件默认落点 */
    val DOWNLOAD_DIR = "${Environment.DIRECTORY_DOWNLOADS}/来自另一台Mac"

    /** 开启开关时，图片/视频直接落到这里，只写一份，相册里自然只有一份 */
    val IMAGE_DIR = "${Environment.DIRECTORY_PICTURES}/MoonDrop"
    val VIDEO_DIR = "${Environment.DIRECTORY_MOVIES}/MoonDrop"

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

    /** 已在相册目录里的条目不必再「存入相册」，按钮也可据此隐藏 */
    fun isInGallery(relativePath: String): Boolean =
        relativePath.startsWith(IMAGE_DIR) || relativePath.startsWith(VIDEO_DIR)

    /**
     * 上次「清空已接收」的时间（秒，与 MediaStore.DATE_ADDED 同单位）。
     * 相册目录里更早的文件属于用户资产，清空时不删文件，只靠这个时间戳把它们挡在列表外。
     */
    fun galleryClearedAt(context: Context): Long =
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_GALLERY_CLEARED_AT, 0L)

    fun markGalleryCleared(context: Context) {
        // 回退 1 秒：避免清空后同一秒收到的新文件被 DATE_ADDED > ? 永久挡在列表外
        val seconds = System.currentTimeMillis() / 1000L - 1
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putLong(KEY_GALLERY_CLEARED_AT, seconds.coerceAtLeast(0L)).apply()
    }
}

/**
 * 接收文件统一发布到 MediaStore，普通文件进「下载」，图片/视频按开关直接进相册目录。
 *
 * 注意：Android 的 MediaStore 集合是按 MIME 对同一张 files 表做的不同视图，不是互斥目录。
 * 把 image/jpeg 放进 Download/ 也会被图库按 media_type 索引；早先「先存下载、再复制一份到
 * Pictures/」的做法因此会让相册出现两份。现在媒体只写一次，物理上和索引上都只有一份。
 */
class MediaStoreStore(context: Context) {

    private val appContext = context.applicationContext
    private val resolver = appContext.contentResolver

    val stagingDir: File = File(appContext.cacheDir, "staging").apply {
        mkdirs()
        // 清掉上次异常退出留下的半截文件
        listFiles()?.forEach { it.delete() }
    }

    private fun collections(): List<Pair<Uri, String>> = listOf(
        MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to GallerySettings.DOWNLOAD_DIR,
        MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to GallerySettings.IMAGE_DIR,
        MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY) to GallerySettings.VIDEO_DIR
    )

    fun save(
        staging: File,
        fileName: String,
        rootName: String?,
        relativePath: String?
    ): ReceivedEntry {
        val displayName = NetUtil.sanitizeName(fileName)
        val mime = mimeType(displayName)
        val isImage = mime.startsWith("image/")
        val isVideo = mime.startsWith("video/")
        val toGallery = (isImage || isVideo) && GallerySettings.isEnabled(appContext)

        val base = when {
            toGallery && isImage -> GallerySettings.IMAGE_DIR
            toGallery && isVideo -> GallerySettings.VIDEO_DIR
            else -> GallerySettings.DOWNLOAD_DIR
        }
        var relative = "$base/"
        for (component in relativeDirectories(relativePath, rootName)) {
            relative += component + "/"
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        // 插入集合要与 RELATIVE_PATH 的主目录匹配，否则部分系统会把文件塞回 Download/
        val collection = when {
            toGallery && isImage ->
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            toGallery && isVideo ->
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val uri = resolver.insert(collection, values)
            ?: throw IOException("无法创建接收文件")

        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IOException("无法写入接收文件")
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
     * 手动「存入相册」：只用于开关关闭时或旧版本留在下载目录里的媒体。
     *
     * 已经落在相册目录的直接返回原 URI，绝不重复插入；否则先复制到相册目录、再删掉下载目录
     * 里的原件（移动语义），保证前后都只有一份。任一步失败都会回滚新建的副本。
     */
    fun saveToGallery(entry: ReceivedEntry): Uri {
        if (GallerySettings.isInGallery(entry.relativePath)) return entry.uri

        val mime = mimeType(entry.name)
        val collection = when {
            mime.startsWith("image/") ->
                MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            mime.startsWith("video/") ->
                MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            else -> throw IOException("只有图片和视频能存入相册")
        }
        val directory = if (mime.startsWith("image/")) {
            GallerySettings.IMAGE_DIR
        } else {
            GallerySettings.VIDEO_DIR
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, entry.name)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, "$directory/")
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
            // 只留一份：副本发布成功后立刻删掉下载目录里的原件
            if (resolver.delete(entry.uri, null, null) == 0) {
                throw IOException("无法移除下载目录里的原件")
            }
            return uri
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            throw error
        }
    }

    /** 三个集合各自按 RELATIVE_PATH 查一遍，路径前缀互斥，不会重复列出同一条记录 */
    fun listReceived(): List<ReceivedEntry> {
        val clearedAt = GallerySettings.galleryClearedAt(appContext)
        val result = mutableListOf<ReceivedEntry>()
        for ((collection, base) in collections()) {
            // 清空时相册目录的文件不删，只把清空之前的那些挡在列表外；新收的仍会显示
            val since = if (GallerySettings.isInGallery(base)) clearedAt else 0L
            result += queryCollection(collection, base, since)
        }
        return result.sortedByDescending { it.modified }
    }

    private fun queryCollection(
        collection: Uri,
        base: String,
        addedAfterSeconds: Long
    ): List<ReceivedEntry> {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.RELATIVE_PATH
        )
        val selection: String
        val args: Array<String>
        if (addedAfterSeconds > 0) {
            selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.MediaColumns.DATE_ADDED} > ?"
            args = arrayOf("$base%", addedAfterSeconds.toString())
        } else {
            selection = "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?"
            args = arrayOf("$base%")
        }
        val result = mutableListOf<ReceivedEntry>()
        try {
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
                            relativePath = cursor.getString(pathIndex) ?: "$base/"
                        )
                    )
                }
            }
        } catch (_: Exception) {
            // 某个集合查不动（定制 ROM 权限差异）时，其余两个仍要正常显示
        }
        return result
    }

    fun delete(entry: ReceivedEntry) {
        resolver.delete(entry.uri, null, null)
    }

    /**
     * 清空已接收：只删除「下载」里的普通文件。
     *
     * 相册目录里的图片/视频已经是用户自己的照片，与 iOS 保持一致——清空不动文件，
     * 只记一个时间戳，让它们从「已接收」列表里消失；之后新收到的媒体仍会正常出现。
     */
    fun clearReceived() {
        val downloads = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        resolver.delete(
            downloads,
            "${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ?",
            arrayOf("${GallerySettings.DOWNLOAD_DIR}%")
        )
        GallerySettings.markGalleryCleared(appContext)
    }

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
