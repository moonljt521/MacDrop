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
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicIntegerArray
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicReferenceArray
import kotlin.concurrent.thread

class TransferClient {

    private data class ChunkTask(
        val sessionIndex: Int,
        val offset: Long,
        val data: ByteArray,
        /** 这一批已完成的文件数；发完一个文件后 +1 */
        val waveFinished: AtomicInteger
    )

    /** 一次 begin 的结果 */
    private enum class BeginState {
        /** 200：会话已建立 */
        ACCEPTED,
        /** 202：等对方确认 */
        PENDING,
        /** 429：对方同时在收的文件太多，稍后重试 */
        BUSY
    }

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
                val remaining = AtomicIntegerArray(IntArray(prepared.size) { chunkCount(prepared[it].size) })
                val sessionArray = AtomicReferenceArray<Session?>(prepared.size)
                val queue = LinkedBlockingQueue<ChunkTask>(PARALLEL_CHUNKS * 2)
                val aborted = AtomicBoolean(false)
                val allDone = AtomicBoolean(false)
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
                                    if (allDone.get() && queue.isEmpty()) break
                                    continue
                                }
                                val index = task.sessionIndex
                                val session = sessionArray.get(index) ?: continue
                                postChunk(session.base, session.transferID, task.offset, task.data)
                                val totalSent = sent.addAndGet(task.data.size.toLong())
                                onProgress(totalSent, total, session.file.name)
                                if (remaining.decrementAndGet(index) == 0) {
                                    // finish 之后接收端才会释放这个文件的会话槽位
                                    finish(session.base, session.transferID)
                                    task.waveFinished.incrementAndGet()
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

                // 分批建会话：接收端同时在收的文件数有上限（8），
                // 一次把几十个文件的会话全建起来会撞上限被拒，整个传输就失败了。
                // 改成「建一批 → 把这批传完（finish 会释放槽位）→ 再建下一批」，
                // 一次拖选多少个文件都能发。
                var index = 0
                while (index < prepared.size && !aborted.get()) {
                    val end = minOf(index + SESSION_WAVE_SIZE, prepared.size)
                    val waveIndices = (index until end).toList()
                    val waveFinished = AtomicInteger(0)

                    for (i in waveIndices) {
                        val file = prepared[i]
                        val id = UUID.randomUUID().toString()
                        val root = if (file.relativePath.contains('/')) {
                            file.relativePath.substringBefore('/')
                        } else {
                            null
                        }
                        val base = announce(
                            bases, id, file, root, batchID, senderName, prepared.size, total
                        )
                        val session = Session(file, id, base)
                        sessions += session
                        sessionArray.set(i, session)
                    }

                    // 空文件没有分块，直接收尾
                    for (i in waveIndices.filter { prepared[it].size == 0L }) {
                        val session = sessionArray.get(i) ?: continue
                        finish(session.base, session.transferID)
                        waveFinished.incrementAndGet()
                    }

                    val readers = waveIndices.map { i ->
                        thread(name = "macdrop-read-$i") {
                            try {
                                resolver.openInputStream(prepared[i].uri)?.use { input ->
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
                                            if (queue.offer(
                                                    ChunkTask(i, offset, chunk, waveFinished),
                                                    300, TimeUnit.MILLISECONDS
                                                )
                                            ) break
                                        }
                                        offset += filled
                                    }
                                } ?: throw IOException(MoonStrings.f("无法读取 %s", prepared[i].name))
                            } catch (t: Throwable) {
                                error.compareAndSet(null, t)
                                aborted.set(true)
                            }
                        }
                    }
                    readers.forEach { it.join() }

                    // 等这一批的文件全部收尾，接收端腾出槽位后再建下一批
                    while (waveFinished.get() < waveIndices.size && !aborted.get()) {
                        Thread.sleep(50)
                    }
                    index = end
                }

                allDone.set(true)
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
        // 对方忙（同时在收的文件太多）时的等待上限
        val busyDeadline = System.currentTimeMillis() + BUSY_RETRY_TIMEOUT_MS
        for (round in 0..1) {
            var baseIndex = 0
            while (baseIndex < bases.size) {
                val base = bases[baseIndex]
                try {
                    when (announceOnce(base, transferID, file, root, batchID, senderName, fileCount, batchBytes)) {
                        BeginState.ACCEPTED -> return base
                        BeginState.PENDING -> return awaitAcceptance(
                            base, transferID, file, root, batchID, senderName, fileCount, batchBytes
                        )
                        BeginState.BUSY -> {
                            // 对方同时在收的文件太多：等它传完一个文件腾出槽位再重试。
                            // 本批只建了 4 个会话（远小于对方上限 8），
                            // 所以等的一定是对方其它传输释放出来的槽位，不会自己把自己堵死。
                            if (System.currentTimeMillis() >= busyDeadline) {
                                throw IOException(MoonStrings.t("对方正在接收其它文件，请稍后重试"))
                            }
                            Thread.sleep(BUSY_RETRY_INTERVAL_MS)
                            continue
                        }
                    }
                } catch (error: ConfirmationRejected) {
                    throw error
                } catch (error: Exception) {
                    lastError = error
                    // 这个地址连不上，换下一个
                    baseIndex += 1
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
                when (announceOnce(base, transferID, file, root, batchID, senderName, fileCount, batchBytes)) {
                    BeginState.ACCEPTED -> return base
                    // 还在等确认（或者对方正忙），继续轮询
                    BeginState.PENDING, BeginState.BUSY -> Unit
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
    ): BeginState {
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
                BeginState.ACCEPTED
            }
            HttpURLConnection.HTTP_ACCEPTED -> {
                check(connection)
                BeginState.PENDING
            }
            429 -> {
                // 对方同时在收的文件太多：等它传完一个文件腾出槽位
                BeginState.BUSY
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

        /**
         * 一次建立多少个接收会话。
         *
         * 接收端同时在收的文件数有上限（8，见 ReceiverServer 的 MAX_SESSIONS），
         * 一次把几十个文件的会话全建起来会撞上上限，被拒后整个传输失败。
         * 改成「建一批 → 传完这批（finish 会让接收端释放会话）→ 再建下一批」，
         * 任意数量的文件都能发，而且不用改协议、对旧版本接收端同样有效。
         * 取 4：既能撑满分块并发，又给对方留一半余量给其它发送方。
         */
        private const val SESSION_WAVE_SIZE = 4

        /** 对方忙时的重试间隔 */
        private const val BUSY_RETRY_INTERVAL_MS = 300L
        /** 对方忙时最多重试多久（对方传完一个文件就会释放一个会话） */
        private const val BUSY_RETRY_TIMEOUT_MS = 30_000L
    }
}
