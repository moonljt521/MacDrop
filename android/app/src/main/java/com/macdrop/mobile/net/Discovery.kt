package com.macdrop.mobile.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.NetworkInterface

/**
 * Android 端 Bonjour 发现：_macdrop._tcp
 * 与 Mac / iOS 端互通；用 TXT id + 本机网卡地址过滤掉自己。
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
    private val mainHandler = Handler(Looper.getMainLooper())
    private var resolving = false
    private var ownPort = 0
    private var listener: NsdManager.DiscoveryListener? = null

    var onPeersChanged: ((List<Peer>) -> Unit)? = null

    fun start(port: Int) {
        ownPort = port
        if (!multicastLock.isHeld) {
            multicastLock.acquire()
        }
        if (listener != null) return

        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}

            override fun onServiceFound(service: NsdServiceInfo) {
                if (service.serviceType.contains(SERVICE_TYPE)) {
                    enqueueResolve(service)
                }
            }

            override fun onServiceLost(service: NsdServiceInfo) {
                // mDNS 会间歇性发 lost，给 8 秒宽限期，避免发送目标在列表里反复消失
                val name = service.serviceName ?: return
                val removal = Runnable {
                    synchronized(lock) {
                        serviceKeys.remove(name)?.let { peers.remove(it) }
                        pendingRemovals.remove(name)
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
                MobileLog.write("发现启动失败：$errorCode")
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                MobileLog.write("发现停止失败：$errorCode")
            }
        }

        listener = discovery
        try {
            nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discovery)
        } catch (error: Exception) {
            MobileLog.write("discoverServices 异常：$error")
            listener = null
        }
    }

    fun stop() {
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

    private fun enqueueResolve(service: NsdServiceInfo) {
        synchronized(lock) {
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

    private fun handleResolved(info: NsdServiceInfo) {
        val address = info.host ?: return
        val host = address.hostAddress?.substringBefore('%') ?: return
        val port = info.port
        if (isSelf(info, host, port)) return

        val name = info.serviceName ?: host
        val peer = Peer(name = name, host = host, port = port)
        synchronized(lock) {
            pendingRemovals.remove(name)?.let { mainHandler.removeCallbacks(it) }
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
    }
}
