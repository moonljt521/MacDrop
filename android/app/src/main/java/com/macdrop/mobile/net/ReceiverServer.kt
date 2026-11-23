package com.macdrop.mobile.net

import com.macdrop.mobile.store.MediaStoreStore
import com.macdrop.mobile.store.ReceivedEntry
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

data class ReceiveConfirmation(
    val batchID: String,
    val senderName: String,
    val fileCount: Int,
    val totalBytes: Long,
    val firstName: String
)

data class ReceiveProgress(val id: String, val name: String, val received: Long, val total: Long)
data class ReceiveStopped(val id: String, val name: String, val reason: String)

class ReceiverServer(
    private val store: MediaStoreStore,
    var deviceName: String,
    var deviceType: String = ""
) {
    private data class Begin(
        val id: String,
        val name: String,
        val path: String,
        val root: String,
        val total: Long,
        val batchID: String
    )

    private data class Batch(
        val confirmation: ReceiveConfirmation,
        var accepted: Boolean?,
        var touched: Long
    )

    private data class Entry(
        val file: File,
        val name: String,
        val path: String,
        val root: String,
        val total: Long,
        val offsets: MutableSet<Long> = mutableSetOf(),
        var receivedBytes: Long = 0,
        var lastPercent: Int = -1,
        var lastActivity: Long = System.currentTimeMillis()
    )

    private val lock = Any()
    private val staging = ConcurrentHashMap<String, Entry>()
    private val pending = mutableMapOf<String, Begin>()
    private val batches = mutableMapOf<String, Batch>()
    private var server: HttpServer? = null
    private val watchdog = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "macdrop-receive-watchdog").apply { isDaemon = true }
    }

    var onProgress: ((ReceiveProgress) -> Unit)? = null
    var onFinished: ((String, ReceivedEntry) -> Unit)? = null
    var onStopped: ((ReceiveStopped) -> Unit)? = null
    var onConfirm: ((ReceiveConfirmation) -> Unit)? = null
    var onConfirmationResolved: ((String) -> Unit)? = null
    var port: Int = 0
        private set

    fun start(preferredPort: Int = 52345): Int {
        val http = HttpServer(preferredPort) { request -> route(request) }
        port = http.start()
        server = http
        watchdog.scheduleWithFixedDelay({ sweep() }, 5, 5, TimeUnit.SECONDS)
        return port
    }

    fun stop() {
        server?.stop()
        server = null
        watchdog.shutdownNow()
        staging.values.forEach { it.file.delete() }
        staging.clear()
        synchronized(lock) {
            pending.clear()
            batches.clear()
        }
    }

    fun resolveConfirmation(batchID: String, accepted: Boolean) {
        val found = synchronized(lock) {
            val batch = batches[batchID] ?: return@synchronized false
            batch.accepted = accepted
            batch.touched = System.currentTimeMillis()
            true
        }
        if (found) onConfirmationResolved?.invoke(batchID)
    }

    private fun route(request: HttpServer.Request): HttpServer.Response {
        return when (request.method to request.path) {
            "GET" to "/macdrop/ping" -> HttpServer.Response.json(
                JSONObject().put("device", deviceName).put("version", 1)
                    .put("port", port).put("type", deviceType).toString()
            )
            "POST" to "/macdrop/begin" -> begin(request)
            "POST" to "/macdrop/chunk" -> chunk(request)
            "POST" to "/macdrop/finish" -> finish(request)
            "POST" to "/macdrop/abort" -> abort(request)
            "POST" to "/macdrop/quit" -> HttpServer.Response.text("仅桌面端支持", 403)
            else -> HttpServer.Response.text("未知接口", 404)
        }
    }

    private fun begin(request: HttpServer.Request): HttpServer.Response {
        val id = request.query["id"]
        val name = request.query["name"]
        val total = request.query["size"]?.toLongOrNull()
        if (id == null || name == null || total == null) return HttpServer.Response.text("缺少参数", 400)
        if (total < 0) return HttpServer.Response.text("文件大小无效", 400)
        if (staging.containsKey(id)) return HttpServer.Response.json("""{"ok":true}""")

        val batchID = request.query["batch"]?.ifBlank { id } ?: id
        val begin = Begin(
            id, name, request.query["path"] ?: "", request.query["root"] ?: "", total, batchID
        )
        val confirmation = ReceiveConfirmation(
            batchID = batchID,
            senderName = request.query["from"]?.ifBlank { "局域网设备" } ?: "局域网设备",
            fileCount = request.query["files"]?.toIntOrNull()?.coerceIn(1, 10_000) ?: 1,
            totalBytes = request.query["bytes"]?.toLongOrNull()?.coerceAtLeast(0L) ?: total,
            firstName = name
        )
        var response: HttpServer.Response
        var confirm: ReceiveConfirmation? = null
        var started: ReceiveProgress? = null
        synchronized(lock) {
            val batch = batches[batchID]
            when {
                batch?.accepted == false -> response = HttpServer.Response.text("对方已拒绝接收", 403)
                batch == null -> {
                    if (pending.size >= MAX_SESSIONS) {
                        response = HttpServer.Response.text("等待确认的传输过多", 429)
                    } else {
                        batches[batchID] = Batch(confirmation, null, System.currentTimeMillis())
                        pending[id] = begin
                        confirm = confirmation
                        response = pendingResponse()
                    }
                }
                batch.accepted == null -> {
                    pending[id] = begin
                    response = pendingResponse()
                }
                else -> response = createSessionLocked(begin).also { result ->
                    if (result.status == 200) started = ReceiveProgress(id, name, 0, total)
                }
            }
        }
        confirm?.let { onConfirm?.invoke(it) }
        started?.let { onProgress?.invoke(it) }
        return response
    }

    private fun createSessionLocked(begin: Begin): HttpServer.Response {
        if (staging.size >= MAX_SESSIONS) return HttpServer.Response.text("同时接收的文件过多", 429)
        if (begin.total > store.stagingDir.usableSpace) {
            return HttpServer.Response.text("接收设备剩余空间不足", 507)
        }
        val file = File(store.stagingDir, "${NetUtil.sanitizeName(begin.id)}__${NetUtil.sanitizeName(begin.name)}")
        if (file.exists()) file.delete()
        if (!file.createNewFile()) return HttpServer.Response.text("无法创建暂存文件", 500)
        staging[begin.id] = Entry(file, begin.name, begin.path, begin.root, begin.total)
        pending.remove(begin.id)
        return HttpServer.Response.json("""{"ok":true}""")
    }

    private fun chunk(request: HttpServer.Request): HttpServer.Response {
        val id = request.query["id"]
        val offset = request.query["offset"]?.toLongOrNull()
        val entry = id?.let { staging[it] }
        if (id == null || offset == null) return HttpServer.Response.text("缺少参数", 400)
        if (entry == null) return HttpServer.Response.text("未知传输 ID", 404)
        synchronized(entry) {
            if (offset < 0 || offset % CHUNK_SIZE != 0L || offset >= entry.total) {
                return HttpServer.Response.text("分块偏移越界", 400)
            }
            val expected = minOf(CHUNK_SIZE.toLong(), entry.total - offset)
            if (request.body.size.toLong() != expected) {
                return HttpServer.Response.text("分块大小不符", 400)
            }
            return try {
                RandomAccessFile(entry.file, "rw").use { handle ->
                    handle.seek(offset)
                    handle.write(request.body)
                }
                if (entry.offsets.add(offset)) entry.receivedBytes += request.body.size
                entry.lastActivity = System.currentTimeMillis()
                val percent = ((entry.receivedBytes * 100) / entry.total).toInt().coerceIn(0, 100)
                if (entry.lastPercent != percent) {
                    entry.lastPercent = percent
                    onProgress?.invoke(ReceiveProgress(id, entry.name, entry.receivedBytes, entry.total))
                }
                HttpServer.Response.json("""{"ok":true}""")
            } catch (error: Exception) {
                HttpServer.Response.text(error.message ?: "写入失败", 500)
            }
        }
    }

    private fun finish(request: HttpServer.Request): HttpServer.Response {
        val id = request.query["id"] ?: return HttpServer.Response.text("缺少参数", 400)
        val entry = synchronized(lock) { staging.remove(id) } ?: return HttpServer.Response.text("未知传输 ID", 404)
        synchronized(entry) {
            if (entry.receivedBytes != entry.total || entry.file.length() != entry.total) {
                entry.file.delete()
                onStopped?.invoke(ReceiveStopped(id, entry.name, "文件不完整"))
                return HttpServer.Response.text("文件不完整：已收 ${entry.receivedBytes} / ${entry.total} 字节", 500)
            }
        }
        return try {
            val saved = store.save(entry.file, entry.name, entry.root, entry.path)
            entry.file.delete()
            onFinished?.invoke(id, saved)
            HttpServer.Response.json(JSONObject().put("ok", true)
                .put("path", saved.relativePath + saved.name).toString())
        } catch (error: Exception) {
            entry.file.delete()
            onStopped?.invoke(ReceiveStopped(id, entry.name, error.message ?: "保存失败"))
            HttpServer.Response.text(error.message ?: "保存失败", 500)
        }
    }

    private fun abort(request: HttpServer.Request): HttpServer.Response {
        val id = request.query["id"]
        val entry = id?.let { staging.remove(it) }
        if (entry != null) {
            entry.file.delete()
            onStopped?.invoke(ReceiveStopped(id, entry.name, "发送方已取消"))
        }
        return HttpServer.Response.json("""{"ok":true}""")
    }

    private fun sweep() {
        val now = System.currentTimeMillis()
        val stopped = mutableListOf<ReceiveStopped>()
        staging.values.forEach { entry ->
            if (now - entry.lastActivity > RECEIVE_IDLE_MS) {
                val id = staging.entries.firstOrNull { it.value === entry }?.key
                if (id != null && staging.remove(id, entry)) {
                    entry.file.delete()
                    stopped += ReceiveStopped(id, entry.name, "接收超时")
                }
            }
        }
        val expiredBatches = mutableListOf<String>()
        synchronized(lock) {
            pending.entries.filter { now - (batches[it.value.batchID]?.touched ?: now) > CONFIRM_TIMEOUT_MS }
                .forEach { (id, begin) ->
                    pending.remove(id)
                    batches[begin.batchID]?.accepted = false
                    expiredBatches += begin.batchID
                }
            batches.entries.removeAll { (_, batch) ->
                batch.accepted != null && now - batch.touched > BATCH_RETENTION_MS
            }
        }
        stopped.forEach { onStopped?.invoke(it) }
        expiredBatches.distinct().forEach { onConfirmationResolved?.invoke(it) }
    }

    private fun pendingResponse() = HttpServer.Response(202, "application/json", """{"confirmation":true}""".toByteArray())

    companion object {
        private const val CHUNK_SIZE = 2 * 1024 * 1024
        private const val MAX_SESSIONS = 8
        private const val RECEIVE_IDLE_MS = 20_000L
        private const val CONFIRM_TIMEOUT_MS = 120_000L
        private const val BATCH_RETENTION_MS = 600_000L
    }
}
