package com.macdrop.mobile.net

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.Executors

/**
 * 不依赖 mDNS 的兜底发现：扫描本机所在网段的 52345 端口。
 *
 * 为什么需要：部分路由器（尤其企业/酒店 Wi-Fi、屏蔽组播的 AP）会让 Bonjour 的广播和查询
 * 全都出不去，各端「在线且在同一 Wi-Fi」却互相看不见。单播 TCP 通常仍然放行，
 * 于是直接 ping 一遍同网段地址就能把人找回来。
 * 局限：只能找到监听默认端口 52345 的设备；跨网段或开了客户端隔离的网络仍然无效。
 */
object SubnetScan {

    data class Found(val host: String, val port: Int, val name: String)

    private const val DEFAULT_PORT = 52345
    private const val THREADS = 24
    private const val CONNECT_TIMEOUT_MS = 800
    private const val READ_TIMEOUT_MS = 800
    /// 单次扫描的硬时限：客户端隔离的网络里每个地址都要等到超时，不能让人等下去
    private const val DEADLINE_MS = 12_000L

    /** 后台执行，结果回到主线程回调 */
    fun run(callback: (List<Found>) -> Unit) {
        val candidates = candidateHosts()
        val main = Handler(Looper.getMainLooper())
        if (candidates.isEmpty()) {
            MobileLog.write("局域网扫描跳过：没有可用的局域网地址")
            main.post { callback(emptyList()) }
            return
        }
        Thread {
            val started = System.currentTimeMillis()
            val pool = Executors.newFixedThreadPool(THREADS)
            val found = Collections.synchronizedList(mutableListOf<Found>())
            val tasks = candidates.map { host ->
                Runnable {
                    if (System.currentTimeMillis() - started > DEADLINE_MS) return@Runnable
                    probe(host)?.let { found.add(it) }
                }
            }
            tasks.forEach { pool.execute(it) }
            pool.shutdown()
            while (!pool.isTerminated) {
                try {
                    pool.awaitTermination(1, java.util.concurrent.TimeUnit.SECONDS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
            val snapshot = found.toList()
            MobileLog.write("局域网扫描完成：探测 ${candidates.size} 个地址，命中 ${snapshot.size} 台")
            main.post { callback(snapshot) }
        }.start()
    }

    /** 本机各网卡所在 /24 段的 .1–.254（排除本机自己） */
    private fun candidateHosts(): List<String> {
        val local = localIPv4s()
        val hosts = linkedSetOf<String>()
        for (ip in local) {
            val parts = ip.split('.')
            if (parts.size != 4 || parts.any { it.toIntOrNull() == null }) continue
            for (last in 1..254) {
                val candidate = "${parts[0]}.${parts[1]}.${parts[2]}.$last"
                if (candidate in local) continue
                hosts.add(candidate)
            }
        }
        return hosts.sorted()
    }

    private fun probe(host: String): Found? {
        var connection: HttpURLConnection? = null
        return try {
            connection = (java.net.URL("http://$host:$DEFAULT_PORT/macdrop/ping").openConnection()
                    as HttpURLConnection).apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                requestMethod = "GET"
            }
            if (connection.responseCode != 200) return null
            val text = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(text)
            Found(
                host = host,
                port = json.optInt("port", DEFAULT_PORT),
                name = json.optString("device").ifEmpty { host }
            )
        } catch (_: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    /** 本机局域网 IPv4，用于 UI 自查与扫描排除自己 */
    fun localIPv4s(): List<String> {
        val result = mutableListOf<String>()
        try {
            for (network in NetworkInterface.getNetworkInterfaces()) {
                if (!network.isUp || network.isLoopback) continue
                for (address in Collections.list(network.inetAddresses)) {
                    if (address !is Inet4Address || address.isLoopbackAddress) continue
                    result.add(address.hostAddress ?: continue)
                }
            }
        } catch (_: Exception) {
        }
        return result
    }
}
