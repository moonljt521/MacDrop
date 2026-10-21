package com.macdrop.mobile.net

import com.macdrop.mobile.store.MediaStoreStore
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * 接收服务：/macdrop/begin | chunk | finish | abort | ping
 */
class ReceiverServer(
    private val store: MediaStoreStore,
    private val deviceName: String
) {

    private data class Entry(
        val file: File,
        val name: String,
        val path: String,
        val root: String,
        val total: Long
    )

    private val staging = ConcurrentHashMap<String, Entry>()
    private var server: HttpServer? = null
    private val lastPercent = AtomicInteger(-1)

    var onProgress: ((Double, String) -> Unit)? = null
    var onFinished: ((String) -> Unit)? = null

    var port: Int = 0
        private set

    fun start(preferredPort: Int = 52345): Int {
        val http = HttpServer(preferredPort) { request -> route(request) }
        port = http.start()
        server = http
        return port
    }

    fun stop() {
        server?.stop()
        server = null
    }

    private fun route(request: HttpServer.Request): HttpServer.Response {
        return when (request.method to request.path) {

            "GET" to "/macdrop/ping" -> {
                val body = JSONObject()
                    .put("device", deviceName)
                    .put("version", 1)
                    .put("port", port)
                    .toString()
                HttpServer.Response.json(body)
            }

            "POST" to "/macdrop/begin" -> {
                val id = request.query["id"]
                val name = request.query["name"]
                val total = request.query["size"]?.toLongOrNull()
                if (id == null || name == null || total == null) {
                    HttpServer.Response.text("缺少参数", 400)
                } else {
                    val file = File(store.stagingDir, "${id}__${NetUtil.sanitizeName(name)}")
                    if (file.exists()) file.delete()
                    if (!file.createNewFile()) {
                        HttpServer.Response.text("无法创建暂存文件", 500)
                    } else {
                        staging[id] = Entry(
                            file = file,
                            name = name,
                            path = request.query["path"] ?: "",
                            root = request.query["root"] ?: "",
                            total = total
                        )
                        lastPercent.set(-1)
                        onProgress?.invoke(0.0, name)
                        HttpServer.Response.json("""{"ok":true}""")
                    }
                }
            }

            "POST" to "/macdrop/chunk" -> {
                val id = request.query["id"]
                val offset = request.query["offset"]?.toLongOrNull()
                val entry = id?.let { staging[it] }
                if (id == null || offset == null) {
                    HttpServer.Response.text("缺少参数", 400)
                } else if (entry == null) {
                    HttpServer.Response.text("未知传输 ID", 404)
                } else {
                    try {
                        RandomAccessFile(entry.file, "rw").use { handle ->
                            handle.seek(offset)
                            handle.write(request.body)
                        }
                        val received = offset + request.body.size
                        val percent = if (entry.total > 0) {
                            ((received * 100) / entry.total).toInt().coerceIn(0, 100)
                        } else {
                            0
                        }
                        if (lastPercent.getAndSet(percent) != percent) {
                            onProgress?.invoke(percent / 100.0, entry.name)
                        }
                        HttpServer.Response.json("""{"ok":true}""")
                    } catch (error: Exception) {
                        HttpServer.Response.text(error.message ?: "写入失败", 500)
                    }
                }
            }

            "POST" to "/macdrop/finish" -> {
                val id = request.query["id"]
                val entry = id?.let { staging.remove(it) }
                if (entry == null) {
                    HttpServer.Response.text("未知传输 ID", 404)
                } else {
                    try {
                        val size = entry.file.length()
                        if (size != entry.total) {
                            entry.file.delete()
                            HttpServer.Response.text("文件不完整：已收 $size / ${entry.total} 字节", 500)
                        } else {
                            val saved = store.save(entry.file, entry.name, entry.root, entry.path)
                            entry.file.delete()
                            onFinished?.invoke(saved.name)
                            val body = JSONObject()
                                .put("ok", true)
                                .put("path", saved.relativePath + saved.name)
                                .toString()
                            HttpServer.Response.json(body)
                        }
                    } catch (error: Exception) {
                        entry.file.delete()
                        HttpServer.Response.text(error.message ?: "保存失败", 500)
                    }
                }
            }

            "POST" to "/macdrop/abort" -> {
                request.query["id"]?.let { id ->
                    staging.remove(id)?.file?.delete()
                }
                HttpServer.Response.json("""{"ok":true}""")
            }

            "POST" to "/macdrop/quit" ->
                HttpServer.Response.text("仅桌面端支持", 403)

            else -> HttpServer.Response.text("未知接口", 404)
        }
    }
}
