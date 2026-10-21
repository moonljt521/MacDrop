package com.macdrop.mobile.net

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import kotlin.concurrent.thread

/**
 * 极简 HTTP/1.1 服务端，接口语义与 macOS / iOS 端一致。
 */
class HttpServer(
    private val preferredPort: Int,
    private val router: (Request) -> Response
) {

    data class Request(
        val method: String,
        val path: String,
        val query: Map<String, String>,
        val headers: Map<String, String>,
        val body: ByteArray
    )

    data class Response(
        val status: Int,
        val contentType: String = "application/json",
        val body: ByteArray = ByteArray(0)
    ) {
        companion object {
            fun json(text: String): Response =
                Response(200, "application/json", text.toByteArray(Charsets.UTF_8))

            fun text(text: String, status: Int = 200): Response =
                Response(status, "text/plain; charset=utf-8", text.toByteArray(Charsets.UTF_8))
        }
    }

    @Volatile
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var running = false

    var port: Int = 0
        private set

    /** 优先用 preferredPort，被占用时退回系统随机端口；返回实际端口。 */
    fun start(): Int {
        val socket = try {
            ServerSocket(preferredPort)
        } catch (_: IOException) {
            ServerSocket(0)
        }
        socket.reuseAddress = true
        serverSocket = socket
        port = socket.localPort
        running = true
        thread(name = "macdrop-http") {
            while (running) {
                val connection = try {
                    socket.accept()
                } catch (_: Exception) {
                    break
                }
                thread(name = "macdrop-conn") { handle(connection) }
            }
        }
        return port
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
    }

    private fun handle(socket: Socket) {
        try {
            socket.use { connection ->
                connection.soTimeout = 60_000
                val input = BufferedInputStream(connection.getInputStream())
                val output = BufferedOutputStream(connection.getOutputStream())

                val header = readHeader(input) ?: return
                val lines = header.split("\r\n")
                val requestLine = lines.firstOrNull()?.split(" ") ?: return
                if (requestLine.size < 2) return

                val method = requestLine[0]
                val target = requestLine[1]

                val headers = HashMap<String, String>()
                for (line in lines.drop(1)) {
                    val colon = line.indexOf(':')
                    if (colon <= 0) continue
                    headers[line.substring(0, colon).trim().lowercase()] =
                        line.substring(colon + 1).trim()
                }

                val length = headers["content-length"]?.toIntOrNull() ?: 0
                // 单个分块 2 MB，留出余量；异常/伪造的长度直接拒掉，避免被撑爆内存
                if (length < 0 || length > MAX_BODY_BYTES) {
                    writeResponse(output, Response.text("请求体过大", 413))
                    return
                }
                val body = ByteArray(length)
                var read = 0
                while (read < length) {
                    val count = input.read(body, read, length - read)
                    if (count < 0) break
                    read += count
                }
                if (read != length) return

                val question = target.indexOf('?')
                val path = if (question >= 0) target.substring(0, question) else target
                val query = if (question >= 0) parseQuery(target.substring(question + 1)) else emptyMap()

                val response = try {
                    router(Request(method, path, query, headers, body))
                } catch (error: Exception) {
                    Response.text("error: ${error.message}", 500)
                }
                writeResponse(output, response)
            }
        } catch (_: Exception) {
        }
    }

    private fun readHeader(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var state = 0
        while (true) {
            val byte = input.read()
            if (byte < 0) return null
            buffer.write(byte)
            state = when {
                byte == '\r'.code && (state == 0 || state == 2) -> state + 1
                byte == '\n'.code && (state == 1 || state == 3) -> state + 1
                else -> 0
            }
            if (state == 4) break
            if (buffer.size() > 64 * 1024) return null
        }
        return buffer.toString("UTF-8")
    }

    private fun writeResponse(output: BufferedOutputStream, response: Response) {
        val reason = when (response.status) {
            200 -> "OK"
            400 -> "Bad Request"
            403 -> "Forbidden"
            404 -> "Not Found"
            409 -> "Conflict"
            500 -> "Internal Server Error"
            else -> "Status"
        }
        val head = buildString {
            append("HTTP/1.1 ${response.status} $reason\r\n")
            append("Content-Type: ${response.contentType}\r\n")
            append("Content-Length: ${response.body.size}\r\n")
            append("Connection: close\r\n\r\n")
        }
        output.write(head.toByteArray(Charsets.UTF_8))
        output.write(response.body)
        output.flush()
    }

    companion object {
        /** 单个分块 2 MB，留出余量；超过就当成异常请求拒掉 */
        const val MAX_BODY_BYTES = 32 * 1024 * 1024

        fun parseQuery(raw: String): Map<String, String> {
            val result = HashMap<String, String>()
            for (pair in raw.split("&")) {
                if (pair.isEmpty()) continue
                val parts = pair.split("=", limit = 2)
                val key = decode(parts[0])
                val value = if (parts.size > 1) decode(parts[1]) else ""
                result[key] = value
            }
            return result
        }

        private fun decode(value: String): String =
            try {
                URLDecoder.decode(value, "UTF-8")
            } catch (_: Exception) {
                value
            }
    }
}
