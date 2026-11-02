package com.macdrop.mobile.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.NetworkInterface

/**
 * Android 端 Bonjour 发现：_macdrop._tcp
 * 与 Mac / iOS 端互通；用 TXT id + 本机网卡地址过滤掉自己。
 *
 * 三件自愈的事，缺一样就会出现「都在线、同一 Wi-Fi，却互相看不见」：
 *  1. 解析失败要重试（Wi-Fi 拥挤时一次超时很常见，放弃就等于这台设备永远不在列表里）；
 *  2. 发现启动失败/长时间没有回调要重启 discoverServices；
 *  3. 切网（Wi-Fi↔蜂窝、换 SSID）后广播与本地地址都变了，必须重来。
 */
class Discovery(context: Context, private val deviceId: String) {

    private val appContext = context.applicationContext
    private val nsd = appContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as WifiManager

    private val multicastLock = wifi.createMulticastLock("macdrop-mdns").apply {
        setReferenceCounted(false)
    }

    private val lock = Any()
    private val peers = LinkedHashMap<String, Peer>()
    private val serviceKeys = HashMap<String, String>()
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private val pendingRemovals = HashMap<String, Runnable>()
    private val resolveRetries = HashMap<String, Runnable>()
    private val resolveAttempts = HashMap<String, Int>()
    private val trackedServices = HashMap<String, NsdServiceInfo>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var resolving = false
    private var ownPort = 0
    private var listener: NsdManager.DiscoveryListener? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private var lastActivity = System.currentTimeMillis()
    private var watchdog: Runnable? = null

    var onPeersChanged: ((List<Peer>) -> Unit)? = null

    private val healthTick = object : Runnable {
        override fun run() {
            val stalled = System.currentTimeMillis() - lastActivity > STALE_AFTER_MS
            if (stalled && listener != null) {
                MobileLog.write("发现超过 ${STALE_AFTER_MS / 1000} 秒没有回调，重启发现")
                restart()
            }
            mainHandler.postDelayed(this, HEALTH_INTERVAL_MS)
        }
    }

    fun start(port: Int) {
        ownPort = port
        if (!multicastLock.isHeld) {
            multicastLock.acquire()
        }
        if (listener != null) return
        startDiscovery()
        watchNetwork()
        if (watchdog == null) {
            watchdog = healthTick
            mainHandler.postDelayed(healthTick, HEALTH_INTERVAL_MS)
        }
    }

    fun stop() {
        watchdog?.let { mainHandler.removeCallbacks(it) }
        watchdog = null
        networkCallback?.let {
            try {
                (appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                    .unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        networkCallback = null
        listener?.let {
            try {
                nsd.stopServiceDiscovery(it)
            } catch (_: Exception) {
            }
        }
        listener = null
        synchronized(lock) {
            for (removal in pendingRemovals.values) mainHandler.removeCallbacks(removal)
            pendingRemovals.clear()
            for (retry in resolveRetries.values) mainHandler.removeCallbacks(retry)
            resolveRetries.clear()
            resolveAttempts.clear()
            trackedServices.clear()
            peers.clear()
            serviceKeys.clear()
            resolveQueue.clear()
            resolving = false
        }
        if (multicastLock.isHeld) {
            multicastLock.release()
        }
        publish()
    }

    /** 组播栈在切网/休眠后常处于「已注册但不再回调」的状态，只能整个重来 */
    private fun restart() {
        val current = listener
        listener = null
        if (current != null) {
            try {
                nsd.stopServiceDiscovery(current)
            } catch (_: Exception) {
            }
        }
        mainHandler.postDelayed({
            if (listener == null) startDiscovery()
        }, 500)
    }

    private fun startDiscovery() {
        if (listener != null) return
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {
                touch()
            }

            override fun onServiceFound(service: NsdServiceInfo) {
                touch()
                if (service.serviceType.contains(SERVICE_TYPE)) {
                    enqueueResolve(service)
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                touch()
                // mDNS 会间歇性发 lost，给 8 秒宽限期，避免发送目标在列表里反复消失
                val name = service.serviceName ?: return
                val removal = Runnable {
                    synchronized(lock) {
                        pendingRemovals.remove(name)
                        val endpoint = serviceKeys.remove(name) ?: return@Runnable
                        trackedServices.remove(name)
                        // 同一台设备可能还在用另一个实例名广播（改名/重连），不能误删
                        if (serviceKeys.values.contains(endpoint)) return@synchronized
                        peers.remove(endpoint)
                    }
                    publish()
                }
                synchronized(lock) {
                    pendingRemovals.remove(name)?.let { mainHandler.removeCallbacks(it) }
                    pendingRemovals[name] = removal
                }
                mainHandler.postDelayed(removal, LOST_GRACE_MS)
            }

            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                MobileLog.write("发现启动失败：$errorCode，2 秒后重试")
                listener = null
                mainHandler.postDelayed({ if (watchdog != null) startDiscovery() }, 2_000)
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                MobileLog.write("发现停止失败：$errorCode")
            }
        }

        listener = discovery
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
            lastActivity = System.currentTimeMillis()
        } catch (error: Exception) {
            MobileLog.write("discoverServices 异常：$error")
            listener = null
        }
    }

    private fun watchNetwork() {
        if (networkCallback != null) return
        val manager = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                MobileLog.write("网络变化，重启设备发现")
                lastActivity = System.currentTimeMillis()
                mainHandler.post { restart() }
            }
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .build()
        try {
            manager.registerNetworkCallback(request, callback)
            networkCallback = callback
        } catch (error: Exception) {
            MobileLog.write("监听网络变化失败：$error")
        }
    }

    private fun touch() {
        lastActivity = System.currentTimeMillis()
    }

    private fun enqueueResolve(service: NsdServiceInfo) {
        synchronized(lock) {
            service.serviceName?.let { trackedServices[it] = service }
            resolveQueue.addLast(service)
            if (resolving) return
            resolving = true
        }
        resolveNext()
    }

    /** NsdManager 同一时间只能解析一个服务，串行处理避免 FAILURE_ALREADY_ACTIVE。 */
    private fun resolveNext() {
        val next = synchronized(lock) {
            val item = resolveQueue.removeFirstOrNull()
            if (item == null) resolving = false
            item
        } ?: return

        try {
            nsd.resolveService(next, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    MobileLog.write("解析失败：${serviceInfo.serviceName} ($errorCode)")
                    scheduleResolveRetry(serviceInfo)
                    resolveNext()
                }

                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    handleResolved(serviceInfo)
                    resolveNext()
                }
            })
        } catch (error: Exception) {
            MobileLog.write("resolveService 异常：$error")
            resolveNext()
        }
    }

    /// Wi-Fi 拥挤时解析超时很常见，放弃就等于这台设备从此不再出现在列表里
    private fun scheduleResolveRetry(service: NsdServiceInfo) {
        val name = service.serviceName ?: return
        val attempts = synchronized(lock) {
            val next = (resolveAttempts[name] ?: 0) + 1
            resolveAttempts[name] = next
            next
        }
        if (attempts > MAX_RESOLVE_ATTEMPTS) {
            synchronized(lock) {
                resolveAttempts.remove(name)
                trackedServices.remove(name)
            }
            return
        }
        val delay = RESOLVE_BACKOFF_MS[attempts - 1]
        val retry = Runnable {
            synchronized(lock) { resolveRetries.remove(name) }
            val tracked = synchronized(lock) { trackedServices[name] } ?: return@Runnable
            MobileLog.write("重新解析：$name（第 $attempts 次）")
            enqueueResolve(tracked)
        }
        synchronized(lock) {
            resolveRetries.remove(name)?.let { mainHandler.removeCallbacks(it) }
            resolveRetries[name] = retry
        }
        mainHandler.postDelayed(retry, delay)
    }

    private fun handleResolved(info: NsdServiceInfo) {
        touch()
        val address = info.host ?: return
        val host = address.hostAddress?.substringBefore('%') ?: return
        val port = info.port
        if (isSelf(info, host, port)) return

        val name = info.serviceName ?: host
        MobileLog.write("对端就绪：$name → $host:$port")
        val peer = Peer(name = name, host = host, port = port)
        synchronized(lock) {
            pendingRemovals.remove(name)?.let { mainHandler.removeCallbacks(it) }
            resolveAttempts.remove(name)
            // 同一实例换了地址（DHCP 续租/切网）：把旧地址那条撤掉，避免列表里出现两个它
            val previous = serviceKeys[name]
            if (previous != null && previous != peer.endpoint) {
                peers.remove(previous)
            }
            peers[peer.endpoint] = peer
            serviceKeys[name] = peer.endpoint
        }
        publish()
    }

    private fun isSelf(info: NsdServiceInfo, host: String, port: Int): Boolean {
        val txtId = info.attributes?.get("id")?.toString(Charsets.UTF_8)
        if (txtId != null && txtId == deviceId) return true
        // 本机地址会随网络变化实时取，避免切网后把自己当成对端
        return port == ownPort && localAddresses().contains(host)
    }

    /** 手动添加 / 扫描得到的对端，不受 lost 事件影响 */
    fun addDirect(peer: Peer) {
        synchronized(lock) {
            peers[peer.endpoint] = peer
        }
        publish()
    }

    private fun publish() {
        val snapshot = synchronized(lock) { peers.values.toList() }
        onPeersChanged?.invoke(snapshot)
    }

    private fun collectLocalAddresses(): Set<String> {
        val result = HashSet<String>()
        try {
            for (network in NetworkInterface.getNetworkInterfaces()) {
                for (address in network.inetAddresses) {
                    val host = address.hostAddress ?: continue
                    result.add(host.substringBefore('%'))
                }
            }
        } catch (_: Exception) {
        }
        return result
    }

    private fun localAddresses(): Set<String> = collectLocalAddresses()

    companion object {
        private const val SERVICE_TYPE = "_macdrop._tcp"
        private const val LOST_GRACE_MS = 8_000L
        private const val STALE_AFTER_MS = 45_000L
        private const val HEALTH_INTERVAL_MS = 15_000L
        private const val MAX_RESOLVE_ATTEMPTS = 3
        private val RESOLVE_BACKOFF_MS = longArrayOf(2_000L, 5_000L, 10_000L)
    }
}
