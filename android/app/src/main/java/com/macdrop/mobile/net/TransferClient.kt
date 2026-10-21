package com.macdrop.mobile.net

import android.content.ContentResolver
import android.net.Uri
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicIntegerArray
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * 发送端：announce → 分块并发上传 → finish，协议与 macOS / iOS 端一致。
 * 分块自带偏移，接收端按偏移随机写；读取时每个文件单独顺序读，写入时多路并发。
 */
class TransferClient {

    fun send(
        files: List<OutgoingFile>,
        peer: Peer,
        resolver: ContentResolver,
        cacheDir: File,
        onProgress: (Long, Long, String) -> Unit,
        onComplete: (Result<Unit>) -> Unit
    ) {
        if (files.isEmpty()) {
            onComplete(Result.success(Unit))
            return
        }

        thread(name = "macdrop-send") {
            try {
                val prepared = files.map { file ->
                    if (file.size <= 0) copyToCache(file, resolver, cacheDir) else file
                }
                val total = prepared.sumOf { it.size }

                // 1) 为每个文件建会话（首选地址连不通时依次尝试备选地址）
                val hosts = ArrayList<String>()
                hosts.add(peer.host)
                hosts.addAll(peer.alternatives)
                val bases = hosts.map { "http://${NetUtil.formatHost(it)}:${peer.port}" }
                val sessions = prepared.map { file ->
                    val id = UUID.randomUUID().toString()
                    val root = if (file.relativePath.contains('/')) {
                        file.relativePath.substringBefore('/')
                    } else {
                        null
                    }
                    val base = announce(bases, id, file, root)
                    Session(file, id, base)
                }
                val transferIDs = sessions.map { it.transferID }
                val chunkCounts = IntArray(prepared.size) { chunkCount(prepared[it].size) }
                val remaining = AtomicIntegerArray(chunkCounts)

                // 2) 顺序读取 + 多路并发发送
                val queue = LinkedBlockingQueue<ChunkTask>(PARALLEL_CHUNKS * 2)
                val aborted = AtomicBoolean(false)
                val readersDone = AtomicBoolean(false)
                val error = AtomicReference<Throwable?>(null)
                val sent = AtomicLong(0)

                val pool = Executors.newFixedThreadPool(PARALLEL_CHUNKS)
                val workers = CountDownLatch(PARALLEL_CHUNKS)
                repeat(PARALLEL_CHUNKS) {
                    pool.execute {
                        try {
                            while (true) {
                                val task = queue.poll(300, TimeUnit.MILLISECONDS)
                                if (task == null) {
                                    if (readersDone.get() && queue.isEmpty()) break
                                    continue
                                }
                                val sessionIndex = task.sessionIndex
                                postChunk(sessions[sessionIndex].base, transferIDs[sessionIndex], task.offset, task.data)
                                val totalSent = sent.addAndGet(task.data.size.toLong())
                                onProgress(totalSent, total, prepared[sessionIndex].name)
                                if (remaining.decrementAndGet(sessionIndex) == 0) {
                                    finish(sessions[sessionIndex].base, transferIDs[sessionIndex])
                                }
                            }
                        } catch (t: Throwable) {
                            error.compareAndSet(null, t)
                            aborted.set(true)
                        } finally {
                            workers.countDown()
                        }
                    }
                }

                // 每个文件一个读取线程：顺序读，避免对 SAF 流做随机 seek
                val readers = prepared.mapIndexed { index, file ->
                    thread(name = "macdrop-read-$index") {
                        try {
                            resolver.openInputStream(file.uri)?.use { input ->
                                val buffer = ByteArray(CHUNK_SIZE)
                                var offset = 0L
                                while (!aborted.get()) {
                                    var filled = 0
                                    while (filled < buffer.size) {
                                        val count = input.read(buffer, filled, buffer.size - filled)
                                        if (count < 0) break
                                        filled += count
                                    }
                                    if (filled == 0) break
                                    // 必须拷贝：入队后缓冲区会被下一轮读取覆盖
                                    val chunk = buffer.copyOf(filled)
                                    while (!aborted.get()) {
                                        if (queue.offer(ChunkTask(index, offset, chunk), 300, TimeUnit.MILLISECONDS)) break
                                    }
                                    offset += filled
                                }
                            } ?: throw IOException("无法读取 ${file.name}")
                        } catch (t: Throwable) {
                            error.compareAndSet(null, t)
                            aborted.set(true)
                        }
                    }
                }

                readers.forEach { it.join() }
                readersDone.set(true)
                workers.await()

                pool.shutdown()
                val failure = error.get()
                if (failure != null) {
                    transferIDs.forEach { abort(peer, it) }
                    onComplete(Result.failure(failure))
                } else {
                    onComplete(Result.success(Unit))
                }
            } catch (error: Exception) {
                onComplete(Result.failure(error))
            }
        }
    }

    private data class ChunkTask(val sessionIndex: Int, val offset: Long, val data: ByteArray)

    private fun chunkCount(size: Long): Int =
        ((size + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt()

    /** SAF 偶尔拿不到大小：先落一份到缓存，保证 announce 的 size 与实际上传字节一致。 */
    private fun copyToCache(
        file: OutgoingFile,
        resolver: ContentResolver,
        cacheDir: File
    ): OutgoingFile {
        val tempDir = File(cacheDir, "outgoing").apply { mkdirs() }
        val temp = File(tempDir, file.name)
        resolver.openInputStream(file.uri)?.use { input ->
            temp.outputStream().use { output -> input.copyTo(output) }
        } ?: throw IOException("无法读取 ${file.name}")
        return OutgoingFile(
            uri = Uri.fromFile(temp),
            name = file.name,
            relativePath = file.relativePath,
            size = temp.length()
        )
    }

    private data class Session(
        val file: OutgoingFile,
        val transferID: String,
        val base: String
    )

    /** 依次尝试各地址；全部失败再整体重试一轮（对端刚唤醒时第一次连接常被丢弃） */
    private fun announce(
        bases: List<String>,
        transferID: String,
        file: OutgoingFile,
        root: String?
    ): String {
        var lastError: Exception? = null
        for (round in 0..1) {
            for (base in bases) {
                try {
                    announceOnce(base, transferID, file, root)
                    return base
                } catch (error: Exception) {
                    lastError = error
                }
            }
            if (round == 0) Thread.sleep(400)
        }
        val reason = lastError?.message ?: "无法连接对端"
        throw IOException("$reason（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）")
    }

    private fun announceOnce(base: String, transferID: String, file: OutgoingFile, root: String?) {
        val query = listOf(
            "id" to transferID,
            "name" to file.name,
            "path" to file.relativePath,
            "size" to file.size.toString(),
            "root" to (root ?: "")
        ).joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }

        // 对端 App 挂起时不会回包，短超时才能快速失败并换地址/重试
        val connection = open("$base/macdrop/begin?$query", connectTimeoutMs = 4_000)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        check(connection)
    }

    private fun postChunk(base: String, transferID: String, offset: Long, data: ByteArray) {
        val url = "$base/macdrop/chunk?id=$transferID&offset=$offset"
        val connection = open(url)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(data.size)
        connection.outputStream.use { it.write(data) }
        check(connection)
    }

    private fun finish(base: String, transferID: String) {
        val url = "$base/macdrop/finish?id=$transferID"
        val connection = open(url)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        check(connection)
    }

    private fun abort(peer: Peer, transferID: String) {
        try {
            val url = "http://${NetUtil.formatHost(peer.host)}:${peer.port}/macdrop/abort?id=$transferID"
            val connection = open(url)
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setFixedLengthStreamingMode(0)
            connection.outputStream.close()
            check(connection)
        } catch (_: Exception) {
        }
    }

    private fun open(url: String, connectTimeoutMs: Int = 15_000): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = connectTimeoutMs
        connection.readTimeout = 60_000
        connection.useCaches = false
        return connection
    }

    private fun check(connection: HttpURLConnection) {
        val code = connection.responseCode
        // 把响应体读完，连接才能被复用（keep-alive）
        val text = try {
            if (code in 200..299) {
                connection.inputStream.bufferedReader().use { it.readText() }
            } else {
                connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            }
        } catch (_: Exception) {
            ""
        }
        if (code !in 200..299) {
            throw IOException("HTTP $code ${text.take(200)}".trim())
        }
    }

    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

    companion object {
        private const val CHUNK_SIZE = 2 * 1024 * 1024

        /** 同时在途的连接数 */
        private const val PARALLEL_CHUNKS = 3
    }
}
