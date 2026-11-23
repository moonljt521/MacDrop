package com.macdrop.mobile.net

import android.content.ContentResolver
import android.net.Uri
import com.macdrop.mobile.ui.MoonStrings
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
import java.util.concurrent.atomic.AtomicIntegerArray
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

class TransferClient {

    fun send(
        files: List<OutgoingFile>,
        peer: Peer,
        senderName: String,
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
            val batchID = UUID.randomUUID().toString()
            val batchCache = File(cacheDir, "outgoing/$batchID")
            val sessions = mutableListOf<Session>()
            try {
                val prepared = files.map { file ->
                    if (file.size <= 0) copyToCache(file, resolver, batchCache) else file
                }
                val total = prepared.sumOf { it.size }
                val bases = (listOf(peer.host) + peer.alternatives).map {
                    "http://${NetUtil.formatHost(it)}:${peer.port}"
                }
                for (file in prepared) {
                    val id = UUID.randomUUID().toString()
                    val root = if (file.relativePath.contains('/')) {
                        file.relativePath.substringBefore('/')
                    } else {
                        null
                    }
                    val base = announce(
                        bases, id, file, root, batchID, senderName, prepared.size, total
                    )
                    sessions += Session(file, id, base)
                }

                sessions.filter { it.file.size == 0L }.forEach { session ->
                    finish(session.base, session.transferID)
                }
                val remaining = AtomicIntegerArray(IntArray(prepared.size) { chunkCount(prepared[it].size) })
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
                                if (aborted.get()) break
                                val task = queue.poll(300, TimeUnit.MILLISECONDS)
                                if (task == null) {
                                    if (readersDone.get() && queue.isEmpty()) break
                                    continue
                                }
                                val index = task.sessionIndex
                                val session = sessions[index]
                                postChunk(session.base, session.transferID, task.offset, task.data)
                                val totalSent = sent.addAndGet(task.data.size.toLong())
                                onProgress(totalSent, total, session.file.name)
                                if (remaining.decrementAndGet(index) == 0) {
                                    finish(session.base, session.transferID)
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
                                    val chunk = buffer.copyOf(filled)
                                    while (!aborted.get()) {
                                        if (queue.offer(ChunkTask(index, offset, chunk), 300, TimeUnit.MILLISECONDS)) break
                                    }
                                    offset += filled
                                }
                            } ?: throw IOException(MoonStrings.f("无法读取 %s", file.name))
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
                    abortAll(sessions)
                    onComplete(Result.failure(failure))
                } else {
                    onComplete(Result.success(Unit))
                }
            } catch (error: Exception) {
                abortAll(sessions)
                onComplete(Result.failure(error))
            } finally {
                batchCache.deleteRecursively()
            }
        }
    }

    private data class ChunkTask(val sessionIndex: Int, val offset: Long, val data: ByteArray)

    private fun chunkCount(size: Long): Int = ((size + CHUNK_SIZE - 1) / CHUNK_SIZE).toInt()

    private fun copyToCache(file: OutgoingFile, resolver: ContentResolver, batchCache: File): OutgoingFile {
        batchCache.mkdirs()
        val temp = File(batchCache, UUID.randomUUID().toString())
        try {
            resolver.openInputStream(file.uri)?.use { input ->
                temp.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IOException(MoonStrings.f("无法读取 %s", file.name))
            return OutgoingFile(Uri.fromFile(temp), file.name, file.relativePath, temp.length())
        } catch (error: Exception) {
            temp.delete()
            throw error
        }
    }

    private data class Session(val file: OutgoingFile, val transferID: String, val base: String)

    private fun announce(
        bases: List<String>,
        transferID: String,
        file: OutgoingFile,
        root: String?,
        batchID: String,
        senderName: String,
        fileCount: Int,
        batchBytes: Long
    ): String {
        var lastError: Exception? = null
        for (round in 0..1) {
            for (base in bases) {
                try {
                    if (announceOnce(base, transferID, file, root, batchID, senderName, fileCount, batchBytes)) {
                        return base
                    }
                    return awaitAcceptance(
                        base, transferID, file, root, batchID, senderName, fileCount, batchBytes
                    )
                } catch (error: ConfirmationRejected) {
                    throw error
                } catch (error: Exception) {
                    lastError = error
                }
            }
            if (round == 0) Thread.sleep(400)
        }
        val reason = lastError?.message ?: MoonStrings.t("无法连接对端")
        throw IOException(MoonStrings.f("%s（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）", reason))
    }

    private fun awaitAcceptance(
        base: String,
        transferID: String,
        file: OutgoingFile,
        root: String?,
        batchID: String,
        senderName: String,
        fileCount: Int,
        batchBytes: Long
    ): String {
        val deadline = System.currentTimeMillis() + CONFIRM_TIMEOUT_MS
        var lastError: Exception? = null
        while (System.currentTimeMillis() < deadline) {
            try {
                if (announceOnce(base, transferID, file, root, batchID, senderName, fileCount, batchBytes)) {
                    return base
                }
            } catch (error: ConfirmationRejected) {
                throw error
            } catch (error: Exception) {
                lastError = error
            }
            Thread.sleep(500)
        }
        throw IOException(lastError?.message ?: MoonStrings.t("等待对方确认接收超时"))
    }

    private fun announceOnce(
        base: String,
        transferID: String,
        file: OutgoingFile,
        root: String?,
        batchID: String,
        senderName: String,
        fileCount: Int,
        batchBytes: Long
    ): Boolean {
        val query = listOf(
            "id" to transferID,
            "name" to file.name,
            "path" to file.relativePath,
            "size" to file.size.toString(),
            "root" to (root ?: ""),
            "batch" to batchID,
            "from" to senderName,
            "files" to fileCount.toString(),
            "bytes" to batchBytes.toString()
        ).joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }
        val connection = open("$base/macdrop/begin?$query", connectTimeoutMs = 4_000)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        return when (connection.responseCode) {
            HttpURLConnection.HTTP_OK -> {
                check(connection)
                true
            }
            HttpURLConnection.HTTP_ACCEPTED -> {
                check(connection)
                false
            }
            else -> {
                val message = responseText(connection)
                if (connection.responseCode == HttpURLConnection.HTTP_FORBIDDEN) {
                    throw ConfirmationRejected(message.ifBlank { "对方已拒绝接收" })
                }
                throw IOException("HTTP ${connection.responseCode} ${message.take(200)}".trim())
            }
        }
    }

    private fun postChunk(base: String, transferID: String, offset: Long, data: ByteArray) {
        var lastError: Exception? = null
        for (attempt in 0 until 3) {
            try {
                postChunkOnce(base, transferID, offset, data)
                return
            } catch (error: Exception) {
                lastError = error
                if (attempt < 2) Thread.sleep(400L * (attempt + 1))
            }
        }
        throw lastError ?: IOException(MoonStrings.t("分块发送失败"))
    }

    private fun postChunkOnce(base: String, transferID: String, offset: Long, data: ByteArray) {
        val connection = open("$base/macdrop/chunk?id=$transferID&offset=$offset")
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(data.size)
        connection.outputStream.use { it.write(data) }
        check(connection)
    }

    private fun finish(base: String, transferID: String) {
        val connection = open("$base/macdrop/finish?id=$transferID")
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        check(connection)
    }

    private fun abortAll(sessions: List<Session>) {
        sessions.forEach { session -> abort(session.base, session.transferID) }
    }

    private fun abort(base: String, transferID: String) {
        try {
            val connection = open("$base/macdrop/abort?id=$transferID", connectTimeoutMs = 10_000)
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
        val text = responseText(connection)
        if (code !in 200..299) throw IOException("HTTP $code ${text.take(200)}".trim())
    }

    private fun responseText(connection: HttpURLConnection): String = try {
        if (connection.responseCode in 200..299) {
            connection.inputStream.bufferedReader().use { it.readText() }
        } else {
            connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        }
    } catch (_: Exception) {
        ""
    }

    private class ConfirmationRejected(message: String) : IOException(message)

    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

    companion object {
        private const val CHUNK_SIZE = 2 * 1024 * 1024
        private const val PARALLEL_CHUNKS = 3
        private const val CONFIRM_TIMEOUT_MS = 300_000L
    }
}
