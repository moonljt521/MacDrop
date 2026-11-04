package com.macdrop.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.IBinder
import com.macdrop.mobile.net.MobileLog
import com.macdrop.mobile.net.ReceiverRuntime
import com.macdrop.mobile.net.ReceiverServer
import com.macdrop.mobile.store.GallerySettings
import com.macdrop.mobile.store.MediaStoreStore
import kotlin.concurrent.thread

/**
 * 前台服务：应用切到后台/锁屏后仍能继续接收文件。
 *
 * 广播（NSD 注册）也放在这里：系统杀掉 Activity 不影响它。
 * 注册失败会被重试，否则「本机在监听、别人却看不到」会一直存在。
 */
class ReceiverService : Service() {

    private var server: ReceiverServer? = null
    private var nsd: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private var registerAttempts = 0
    private var sameNameFailures = 0
    private var baseName = ""
    private var instanceSuffix = 0
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.notification_channel),
                NotificationManager.IMPORTANCE_LOW
            )
        )
        startForeground(
            NOTIFICATION_ID,
            buildNotification(0),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )

        val store = MediaStoreStore(this)
        val receiver = ReceiverServer(store, DeviceIdentity.name(this))
        receiver.onProgress = { fraction, name ->
            ReceiverRuntime.receiving = true
            ReceiverRuntime.progress = fraction
            ReceiverRuntime.statusText = "接收中 ${(fraction * 100).toInt()}% · $name"
            ReceiverRuntime.notifyChanged()
        }
        receiver.onFinished = { entry ->
            ReceiverRuntime.receiving = false
            ReceiverRuntime.progress = 1.0
            ReceiverRuntime.statusText = ""
            ReceiverRuntime.lastResult = "已接收：${entry.name}"
            ReceiverRuntime.notifyChanged()
            if (GallerySettings.isEnabled(this) && GallerySettings.isMedia(entry.name)) {
                thread(name = "macdrop-gallery") {
                    val saved = runCatching { store.saveToGallery(entry) }.getOrNull()
                    ReceiverRuntime.lastResult = if (saved != null) {
                        "已接收并存入相册：${entry.name}"
                    } else {
                        "已接收：${entry.name}（存入相册失败）"
                    }
                    ReceiverRuntime.notifyChanged()
                }
            }
        }

        val actualPort = receiver.start(PREFERRED_PORT)
        server = receiver
        ReceiverRuntime.port = actualPort
        ReceiverRuntime.notifyChanged()
        MobileLog.write("接收服务监听 $actualPort")

        manager.notify(NOTIFICATION_ID, buildNotification(actualPort))
        advertise(actualPort)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 改名后 Activity 会发这个：旧的注册必须先撤掉，再按新名字重新注册
        if (intent?.action == ACTION_READVERTISE) {
            server?.deviceName = DeviceIdentity.name(this)
            reregister()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mainHandler.removeCallbacksAndMessages(null)
        registrationListener?.let {
            try {
                nsd?.unregisterService(it)
            } catch (_: Exception) {
            }
        }
        registrationListener = null
        server?.stop()
        server = null
        super.onDestroy()
    }

    private fun advertise(port: Int) {
        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        nsd = manager
        val desired = DeviceIdentity.name(this)
        // 只有用户真改名才清掉后缀；重连/重试要保留已经避过撞车的那个名字
        if (desired != baseName) {
            baseName = desired
            instanceSuffix = 0
        }
        val instanceName = serviceInstanceName(
            if (instanceSuffix == 0) baseName else "$baseName ($instanceSuffix)"
        )
        val info = NsdServiceInfo().apply {
            serviceName = instanceName
            serviceType = SERVICE_TYPE
            this.port = port
            setAttribute("id", DeviceIdentity.id(this@ReceiverService))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                registerAttempts = 0
                sameNameFailures = 0
                ReceiverRuntime.advertising = true
                ReceiverRuntime.advertiseError = ""
                ReceiverRuntime.notifyChanged()
                MobileLog.write("广播成功：${serviceInfo.serviceName} :$port")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                ReceiverRuntime.advertising = false
                ReceiverRuntime.advertiseError = describeFailure(errorCode)
                ReceiverRuntime.notifyChanged()
                MobileLog.write("广播失败：$errorCode")
                // 同一个名字连失败两次，几乎一定是网段里已有同名实例（第二台会永远隐身）
                sameNameFailures++
                if (sameNameFailures >= 2) {
                    instanceSuffix++
                    sameNameFailures = 0
                    MobileLog.write("广播名「$baseName」被占用，改用「$baseName ($instanceSuffix)」重试")
                }
                retryRegister(port)
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {
                registrationListener = null
            }

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                MobileLog.write("撤销广播失败：$errorCode")
            }
        }
        registrationListener = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (error: Exception) {
            MobileLog.write("registerService 异常：$error")
            ReceiverRuntime.advertising = false
            retryRegister(port)
        }
        // 有些系统（定制 ROM、模拟器）注册成功却不回调，12 秒后自己再注册一次，
        // 保证记录真的发了出去；只补一次，避免无限循环
        mainHandler.postDelayed({
            if (!ReceiverRuntime.advertising &&
                ReceiverRuntime.advertiseError.isEmpty() &&
                registerAttempts == 0
            ) {
                MobileLog.write("广播状态未确认，重新注册一次")
                registerAttempts = 1
                reregister()
            }
        }, 12_000)
    }

    private fun retryRegister(port: Int) {
        if (registerAttempts >= MAX_REGISTER_ATTEMPTS) return
        registerAttempts++
        val delay = REGISTER_BACKOFF_MS[(registerAttempts - 1).coerceAtMost(REGISTER_BACKOFF_MS.lastIndex)]
        MobileLog.write("${delay}ms 后重新广播（第 $registerAttempts 次）")
        mainHandler.postDelayed({
            if (registrationListener == null) advertise(port) else reregister()
        }, delay)
    }

    /** 撤掉旧注册，随后用当前名字与端口重新注册 */
    private fun reregister() {
        val listener = registrationListener
        val port = ReceiverRuntime.port
        if (listener != null) {
            try {
                nsd?.unregisterService(listener)
            } catch (_: Exception) {
            }
            registrationListener = null
        }
        ReceiverRuntime.advertising = false
        if (port > 0) {
            mainHandler.postDelayed({ advertise(port) }, REREGISTER_DELAY_MS)
        }
    }

    private fun buildNotification(port: Int): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val text = if (port > 0) {
            "监听端口 $port · 等待接收文件"
        } else {
            getString(R.string.notification_text)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_moondrop)
            .setContentTitle(getString(R.string.notification_title))
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    /**
     * mDNS 实例名规范：最长 63 字节（UTF-8），且不能含空格等控制字符。
     * Build.MODEL 常常带空格（"Pixel 8 Pro"），不处理的话 NSD 注册可能直接失败，
     * 那台设备就会在所有别的设备列表里彻底隐身。
     */
    private fun serviceInstanceName(desired: String): String {
        val cleaned = desired.replace(Regex("[\\s\\p{Cntrl}]"), "_")
            .trim('_')
            .ifEmpty { "MoonDrop" }
        var bytes = 0
        val builder = StringBuilder()
        for (ch in cleaned) {
            val size = ch.toString().toByteArray(Charsets.UTF_8).size
            if (bytes + size > 60) break
            bytes += size
            builder.append(ch)
        }
        return builder.toString().ifEmpty { "MoonDrop" }
    }

    /** 把 NsdManager 的失败码翻译成人话，直接显示在「本机」卡片上 */
    private fun describeFailure(errorCode: Int): String = when (errorCode) {
        NsdManager.FAILURE_ALREADY_ACTIVE -> "注册失败：服务名已被占用（会自动换个名字重试）"
        NsdManager.FAILURE_BAD_PARAMETERS -> "注册失败：参数不合法（服务名可能含不支持的字符）"
        NsdManager.FAILURE_INTERNAL_ERROR -> "注册失败：系统内部错误"
        NsdManager.FAILURE_MAX_LIMIT -> "注册失败：超过系统上限"
        NsdManager.FAILURE_OPERATION_NOT_RUNNING -> "注册失败：操作未在运行"
        else -> "注册失败：代码 $errorCode"
    }

    companion object {
        private const val CHANNEL_ID = "macdrop_receive"
        private const val NOTIFICATION_ID = 1
        private const val PREFERRED_PORT = 52345
        private const val SERVICE_TYPE = "_macdrop._tcp"
        private const val MAX_REGISTER_ATTEMPTS = 6
        private const val REREGISTER_DELAY_MS = 700L
        private val REGISTER_BACKOFF_MS = longArrayOf(2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 60_000L)

        const val ACTION_READVERTISE = "com.macdrop.mobile.action.READVERTISE"
    }
}
