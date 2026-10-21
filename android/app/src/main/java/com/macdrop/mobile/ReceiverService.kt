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
import com.macdrop.mobile.store.MediaStoreStore

/**
 * 前台服务：应用切到后台/锁屏后仍能继续接收文件。
 */
class ReceiverService : Service() {

    private var server: ReceiverServer? = null
    private var nsd: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

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
        val receiver = ReceiverServer(store, DeviceIdentity.name())
        receiver.onProgress = { fraction, name ->
            ReceiverRuntime.receiving = true
            ReceiverRuntime.progress = fraction
            ReceiverRuntime.statusText = "接收中 ${(fraction * 100).toInt()}% · $name"
            ReceiverRuntime.notifyChanged()
        }
        receiver.onFinished = { name ->
            ReceiverRuntime.receiving = false
            ReceiverRuntime.progress = 1.0
            ReceiverRuntime.statusText = ""
            ReceiverRuntime.lastResult = "已接收：$name"
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
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
        val info = NsdServiceInfo().apply {
            serviceName = DeviceIdentity.name()
            serviceType = "_macdrop._tcp"
            this.port = port
            setAttribute("id", DeviceIdentity.id(this@ReceiverService))
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {
                MobileLog.write("广播成功：${serviceInfo.serviceName} :$port")
            }

            override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                MobileLog.write("广播失败：$errorCode")
            }

            override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}

            override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        }
        registrationListener = listener
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (error: Exception) {
            MobileLog.write("registerService 异常：$error")
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

    companion object {
        private const val CHANNEL_ID = "macdrop_receive"
        private const val NOTIFICATION_ID = 1
        private const val PREFERRED_PORT = 52345
    }
}
