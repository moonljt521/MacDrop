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
 *
 * 扫描是流式的：每探测完一个地址就上报一次真实进度，命中哪台就立刻回调哪台。
 * 这样界面可以边扫边显示，而不是等最长 12 秒后一次性砸下一堆结果。
 */
object SubnetScan {

    data class Found(val host: String, val port: Int, val name: String)

    /** 扫描过程中的真实状态。probed 是真的探测过多少个地址。 */
    data class Progress(val probed: Int, val total: Int, val found: List<Found>)

    private const val DEFAULT_PORT = 52345
    private const val THREADS = 24
    private const val CONNECT_TIMEOUT_MS = 800
    private const val READ_TIMEOUT_MS = 800
    /// 单次扫描的硬时限：客户端隔离的网络里每个地址都要等到超时，不能让人等下去
    private const val DEADLINE_MS = 12_000L
    /// 普通进度上报的最小间隔：探测很快时不必每个地址都通知界面
    internal const val REPORT_INTERVAL_MS = 80L

    /** 后台执行，onProgress 与 completion 都在主线程回调 */
    fun run(onProgress: (Progress) -> Unit, completion: (Progress) -> Unit) {
        val candidates = candidateHosts()
        val main = Handler(Looper.getMainLooper())
        if (candidates.isEmpty()) {
            MobileLog.write("局域网扫描跳过：没有可用的局域网地址")
            main.post { completion(Progress(0, 0, emptyList())) }
            return
        }
        val state = ScanState(candidates.size, main, onProgress)
        Thread {
            val started = System.currentTimeMillis()
            val pool = Executors.newFixedThreadPool(THREADS)
            val tasks = candidates.map { host ->
                Runnable {
                    if (System.currentTimeMillis() - started > DEADLINE_MS) return@Runnable
                    state.record(probe(host))
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
            val snapshot = state.snapshot()
            MobileLog.write(
                "局域网扫描完成：探测 ${snapshot.probed}/${snapshot.total} 个地址，命中 ${snapshot.found.size} 台"
            )
            main.post { completion(snapshot) }
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

/** 扫描过程中的共享状态：跨线程累积探测计数与命中结果。 */
private class ScanState(
    private val total: Int,
    private val main: Handler,
    private val emit: (SubnetScan.Progress) -> Unit
) {
    private val lock = Any()
    private var probed = 0
    private val found = mutableListOf<SubnetScan.Found>()
    private var lastReport = 0L

    /** 记录一次探测结果。命中立刻上报，普通进度按间隔节流，避免界面被刷屏。 */
    fun record(hit: SubnetScan.Found?) {
        val snapshot: SubnetScan.Progress
        val shouldReport: Boolean
        synchronized(lock) {
            probed += 1
            if (hit != null) found.add(hit)
            val now = System.currentTimeMillis()
            shouldReport = hit != null || now - lastReport >= SubnetScan.REPORT_INTERVAL_MS
            if (shouldReport) lastReport = now
            snapshot = SubnetScan.Progress(probed, total, found.toList())
        }
        if (shouldReport) main.post { emit(snapshot) }
    }

    fun snapshot(): SubnetScan.Progress =
        synchronized(lock) { SubnetScan.Progress(probed, total, found.toList()) }
}
