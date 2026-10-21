package com.macdrop.mobile.net

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArrayList

object MobileLog {
    fun write(message: String) {
        android.util.Log.i("MoonDropMobile", message)
    }
}

/** 接收服务与 Activity 之间的轻量状态桥。 */
object ReceiverRuntime {

    @Volatile
    var port: Int = 0

    @Volatile
    var receiving: Boolean = false

    @Volatile
    var progress: Double = 0.0

    @Volatile
    var statusText: String = ""

    @Volatile
    var lastResult: String = ""

    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    fun notifyChanged() {
        main.post {
            for (listener in listeners) listener()
        }
    }
}
