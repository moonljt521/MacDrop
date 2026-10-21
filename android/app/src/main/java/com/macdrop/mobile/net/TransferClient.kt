package com.macdrop.mobile.net

import android.content.ContentResolver
import android.net.Uri
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID
import kotlin.concurrent.thread

/**
 * 发送端：announce → 顺序 2 MiB 分块 → finish，协议与 macOS / iOS 端一致。
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
                var sent = 0L

                for (file in prepared) {
                    val transferID = UUID.randomUUID().toString()
                    val root = if (file.relativePath.contains('/')) {
                        file.relativePath.substringBefore('/')
                    } else {
                        null
                    }

                    announce(peer, transferID, file, root)

                    resolver.openInputStream(file.uri)?.use { input ->
                        val buffer = ByteArray(CHUNK_SIZE)
                        var offset = 0L
                        while (true) {
                            var filled = 0
                            while (filled < buffer.size) {
                                val count = input.read(buffer, filled, buffer.size - filled)
                                if (count < 0) break
                                filled += count
                            }
                            if (filled == 0) break
                            val chunk = if (filled == buffer.size) buffer else buffer.copyOf(filled)
                            postChunk(peer, transferID, offset, chunk)
                            offset += filled
                            sent += filled
                            onProgress(sent, total, file.name)
                        }
                    } ?: throw IOException("无法读取 ${file.name}")

                    finish(peer, transferID)
                }
                onComplete(Result.success(Unit))
            } catch (error: Exception) {
                onComplete(Result.failure(error))
            }
        }
    }

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

    private fun announce(peer: Peer, transferID: String, file: OutgoingFile, root: String?) {
        val query = listOf(
            "id" to transferID,
            "name" to file.name,
            "path" to file.relativePath,
            "size" to file.size.toString(),
            "root" to (root ?: "")
        ).joinToString("&") { (key, value) -> "${encode(key)}=${encode(value)}" }

        val connection = open("http://${NetUtil.formatHost(peer.host)}:${peer.port}/macdrop/begin?$query")
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        check(connection)
    }

    private fun postChunk(peer: Peer, transferID: String, offset: Long, data: ByteArray) {
        val url = "http://${NetUtil.formatHost(peer.host)}:${peer.port}" +
            "/macdrop/chunk?id=$transferID&offset=$offset"
        val connection = open(url)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(data.size)
        connection.outputStream.use { it.write(data) }
        check(connection)
    }

    private fun finish(peer: Peer, transferID: String) {
        val url = "http://${NetUtil.formatHost(peer.host)}:${peer.port}/macdrop/finish?id=$transferID"
        val connection = open(url)
        connection.requestMethod = "POST"
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(0)
        connection.outputStream.close()
        check(connection)
    }

    private fun open(url: String): HttpURLConnection {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 60_000
        connection.useCaches = false
        return connection
    }

    private fun check(connection: HttpURLConnection) {
        val code = connection.responseCode
        if (code !in 200..299) {
            val message = try {
                connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
            } catch (_: Exception) {
                ""
            }
            throw IOException("HTTP $code ${message.take(200)}".trim())
        }
        try {
            connection.inputStream?.close()
        } catch (_: Exception) {
        }
    }

    private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

    companion object {
        private const val CHUNK_SIZE = 2 * 1024 * 1024
    }
}
