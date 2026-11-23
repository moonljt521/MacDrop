package com.macdrop.mobile.net

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList

object MobileLog {
    fun write(message: String) {
        Log.i("MoonDropMobile", message)
    }
}

object ReceiverRuntime {
    @Volatile var port: Int = 0
    @Volatile var receiving: Boolean = false
    @Volatile var progress: Double = 0.0
    @Volatile var statusText: String = ""
    @Volatile var lastResult: String = ""
    @Volatile var advertising: Boolean = false
    @Volatile var advertiseError: String = ""

    private val confirmations = ConcurrentHashMap<String, ReceiveConfirmation>()
    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private val main = Handler(Looper.getMainLooper())

    val pendingConfirmations: List<ReceiveConfirmation>
        get() = confirmations.values.sortedBy { it.batchID }

    fun addConfirmation(request: ReceiveConfirmation) {
        confirmations[request.batchID] = request
    }

    fun removeConfirmation(batchID: String) {
        confirmations.remove(batchID)
    }

    fun clearConfirmations() {
        confirmations.clear()
    }

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    fun notifyChanged() {
        main.post { listeners.forEach { it() } }
    }
}
