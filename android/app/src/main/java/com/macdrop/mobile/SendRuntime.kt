package com.macdrop.mobile

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.macdrop.mobile.net.OutgoingFile
import com.macdrop.mobile.net.Peer
import com.macdrop.mobile.net.TransferClient
import com.macdrop.mobile.store.SentStore
import java.util.concurrent.CopyOnWriteArrayList

data class SendCompletion(
    val result: Result<Unit>,
    val files: List<OutgoingFile>,
    val peer: Peer,
    val restoreUris: List<Uri>
)

object SendRuntime {
    private val client = TransferClient()
    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArrayList<() -> Unit>()
    private var completion: SendCompletion? = null

    var sending = false
        private set
    var progress = 0.0
        private set
    var currentName = ""
        private set
    var largeFile = false
        private set

    fun start(context: Context, files: List<OutgoingFile>, peer: Peer, restoreUris: List<Uri>) {
        if (sending || files.isEmpty()) return
        val appContext = context.applicationContext
        sending = true
        progress = 0.0
        currentName = files.first().name
        largeFile = files.sumOf { it.size } > 100L * 1024L * 1024L
        notifyChanged()
        client.send(
            files = files,
            peer = peer,
            senderName = DeviceIdentity.name(appContext),
            resolver = appContext.contentResolver,
            cacheDir = appContext.cacheDir,
            onProgress = { sent, total, name ->
                main.post {
                    if (!sending) return@post
                    progress = maxOf(progress, if (total > 0) sent.toDouble() / total else 0.0)
                    currentName = name
                    notifyChanged()
                }
            },
            onComplete = { result ->
                main.post {
                    sending = false
                    progress = if (result.isSuccess) 1.0 else 0.0
                    completion = SendCompletion(result, files, peer, restoreUris)
                    if (result.isSuccess) {
                        SentStore.add(
                            appContext,
                            files.map { it.name },
                            peer.name,
                            files.sumOf { it.size }
                        )
                    }
                    notifyChanged()
                }
            }
        )
    }

    fun consumeCompletion(): SendCompletion? {
        val current = completion
        completion = null
        return current
    }

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
        main.post { if (listeners.contains(listener)) listener() }
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    private fun notifyChanged() {
        main.post { listeners.forEach { it() } }
    }
}
