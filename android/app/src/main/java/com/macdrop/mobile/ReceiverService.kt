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
import com.macdrop.mobile.net.ReceiveConfirmation
import com.macdrop.mobile.net.ReceiveProgress
import com.macdrop.mobile.net.ReceiverRuntime
import com.macdrop.mobile.net.ReceiverServer
import com.macdrop.mobile.store.GallerySettings
import com.macdrop.mobile.store.MediaStoreStore
import com.macdrop.mobile.ui.MoonPrefs
import com.macdrop.mobile.ui.MoonStrings

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
    private val activeLock = Any()
    private val active = mutableMapOf<String, ReceiveProgress>()

    override fun onCreate() {
        super.onCreate()

        // 进程重启后服务可能比 Activity 先起来，通知文案得自己读一次偏好
        MoonPrefs.init(this)
        MoonStrings.language = MoonPrefs.language

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, MoonStrings.t("文件接收"), NotificationManager.IMPORTANCE_LOW)
        )
        manager.createNotificationChannel(
            NotificationChannel(CONFIRM_CHANNEL_ID, MoonStrings.t("接收确认"), NotificationManager.IMPORTANCE_HIGH)
        )
        startForeground(
            NOTIFICATION_ID,
            buildNotification(0),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        )

        val store = MediaStoreStore(this)
        store.cleanupStaging()
        val receiver = ReceiverServer(store, DeviceIdentity.name(this), DeviceIdentity.type(this))
        receiver.onProgress = { progress ->
            synchronized(activeLock) { active[progress.id] = progress }
            publishReceiveState()
        }
        receiver.onFinished = { id, entry ->
            synchronized(activeLock) { active.remove(id) }
            publishReceiveState()
            ReceiverRuntime.lastResult = if (GallerySettings.isInGallery(entry.relativePath)) {
                MoonStrings.f("已接收并存入相册：%s", entry.name)
            } else {
                MoonStrings.f("已接收：%s", entry.name)
            }
            ReceiverRuntime.notifyChanged()
        }
        receiver.onStopped = { stopped ->
            synchronized(activeLock) { active.remove(stopped.id) }
            publishReceiveState()
            ReceiverRuntime.lastResult = "${stopped.reason}：${stopped.name}"
            ReceiverRuntime.notifyChanged()
        }
        receiver.onConfirm = { confirmation ->
            ReceiverRuntime.addConfirmation(confirmation)
            showConfirmationNotification(confirmation)
            ReceiverRuntime.notifyChanged()
        }
        receiver.onConfirmationResolved = { batchID ->
            ReceiverRuntime.removeConfirmation(batchID)
            manager.cancel(CONFIRM_NOTIFICATION_ID)
            ReceiverRuntime.pendingConfirmations.firstOrNull()?.let { showConfirmationNotification(it) }
            ReceiverRuntime.notifyChanged()
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
        when (intent?.action) {
            ACTION_READVERTISE -> {
                server?.deviceName = DeviceIdentity.name(this)
                reregister()
            }
            ACTION_CONFIRM_ACCEPT, ACTION_CONFIRM_REJECT -> {
                val batchID = intent.getStringExtra(EXTRA_BATCH_ID)
                if (!batchID.isNullOrEmpty()) {
                    server?.resolveConfirmation(batchID, intent.action == ACTION_CONFIRM_ACCEPT)
                }
            }
        }
        return START_STICKY
    }

    private fun publishReceiveState() {
        val sessions = synchronized(activeLock) { active.values.toList() }
        val received = sessions.sumOf { it.received }
        val total = sessions.sumOf { it.total }
        val fraction = if (total > 0) received.toDouble() / total else if (sessions.isEmpty()) 1.0 else 0.0
        ReceiverRuntime.receiving = sessions.isNotEmpty()
        ReceiverRuntime.progress = fraction.coerceIn(0.0, 1.0)
        ReceiverRuntime.statusText = if (sessions.isEmpty()) "" else {
            val detail = if (sessions.size == 1) sessions.first().name else MoonStrings.f("%d 个文件", sessions.size)
            MoonStrings.f("接收中 %d%% · %s", (ReceiverRuntime.progress * 100).toInt(), detail)
        }
        ReceiverRuntime.notifyChanged()
    }

    private fun showConfirmationNotification(confirmation: ReceiveConfirmation) {
        val openIntent = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val accept = PendingIntent.getService(
            this, confirmation.batchID.hashCode(), confirmationIntent(ACTION_CONFIRM_ACCEPT, confirmation.batchID),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val reject = PendingIntent.getService(
            this, confirmation.batchID.hashCode() + 1, confirmationIntent(ACTION_CONFIRM_REJECT, confirmation.batchID),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val size = android.text.format.Formatter.formatFileSize(this, confirmation.totalBytes)
        val notification = Notification.Builder(this, CONFIRM_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_moondrop)
            .setContentTitle(MoonStrings.f("%s 请求发送文件", confirmation.senderName))
            .setContentText(MoonStrings.f("%d 个文件 · %s", confirmation.fileCount, size))
            .setContentIntent(openIntent)
            .setAutoCancel(true)
            .addAction(Notification.Action.Builder(null, MoonStrings.t("拒绝"), reject).build())
            .addAction(Notification.Action.Builder(null, MoonStrings.t("接收"), accept).build())
            .build()
        getSystemService(NotificationManager::class.java).notify(CONFIRM_NOTIFICATION_ID, notification)
    }

    private fun confirmationIntent(action: String, batchID: String): Intent =
        Intent(this, ReceiverService::class.java).setAction(action).putExtra(EXTRA_BATCH_ID, batchID)

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
        ReceiverRuntime.receiving = false
        ReceiverRuntime.statusText = ""
        ReceiverRuntime.clearConfirmations()
        getSystemService(NotificationManager::class.java).cancel(CONFIRM_NOTIFICATION_ID)
        ReceiverRuntime.notifyChanged()
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
            // type 告诉对端本机是手机还是平板，对端据此画对应形状的图标
            setAttribute("type", DeviceIdentity.type(this@ReceiverService))
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
            MoonStrings.f("监听端口 %d · 等待接收文件", port)
        } else {
            MoonStrings.t("等待局域网内的设备发送文件")
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_moondrop)
            .setContentTitle(MoonStrings.t("MoonDrop 正在接收文件"))
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
        NsdManager.FAILURE_ALREADY_ACTIVE -> MoonStrings.t("注册失败：服务名已被占用（会自动换个名字重试）")
        NsdManager.FAILURE_BAD_PARAMETERS -> MoonStrings.t("注册失败：参数不合法（服务名可能含不支持的字符）")
        NsdManager.FAILURE_INTERNAL_ERROR -> MoonStrings.t("注册失败：系统内部错误")
        NsdManager.FAILURE_MAX_LIMIT -> MoonStrings.t("注册失败：超过系统上限")
        NsdManager.FAILURE_OPERATION_NOT_RUNNING -> MoonStrings.t("注册失败：操作未在运行")
        else -> MoonStrings.f("注册失败：代码 %d", errorCode)
    }

    companion object {
        private const val CHANNEL_ID = "macdrop_receive"
        private const val CONFIRM_CHANNEL_ID = "macdrop_receive_confirmation"
        private const val NOTIFICATION_ID = 1
        private const val CONFIRM_NOTIFICATION_ID = 2
        private const val PREFERRED_PORT = 52345
        private const val SERVICE_TYPE = "_macdrop._tcp"
        private const val MAX_REGISTER_ATTEMPTS = 6
        private const val REREGISTER_DELAY_MS = 700L
        private val REGISTER_BACKOFF_MS = longArrayOf(2_000L, 5_000L, 10_000L, 20_000L, 30_000L, 60_000L)

        const val ACTION_READVERTISE = "com.macdrop.mobile.action.READVERTISE"
        const val ACTION_CONFIRM_ACCEPT = "com.macdrop.mobile.action.CONFIRM_ACCEPT"
        const val ACTION_CONFIRM_REJECT = "com.macdrop.mobile.action.CONFIRM_REJECT"
        const val EXTRA_BATCH_ID = "batch_id"
    }
}
