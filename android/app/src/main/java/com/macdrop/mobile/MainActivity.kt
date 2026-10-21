package com.macdrop.mobile

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.macdrop.mobile.net.Discovery
import com.macdrop.mobile.net.NetUtil
import com.macdrop.mobile.net.OutgoingFile
import com.macdrop.mobile.net.Peer
import com.macdrop.mobile.net.ReceiverRuntime
import com.macdrop.mobile.net.TransferClient
import com.macdrop.mobile.store.MediaStoreStore
import com.macdrop.mobile.store.ReceivedEntry
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : Activity() {

    private lateinit var localName: TextView
    private lateinit var localPort: TextView
    private lateinit var peersContainer: LinearLayout
    private lateinit var sendHint: TextView
    private lateinit var sendFileButton: Button
    private lateinit var sendFolderButton: Button
    private lateinit var transferCard: LinearLayout
    private lateinit var progressBar: ProgressBar
    private lateinit var transferStatus: TextView
    private lateinit var pendingCard: LinearLayout
    private lateinit var pendingTitle: TextView
    private lateinit var pendingSendButton: Button
    private val pendingUris = mutableListOf<Uri>()
    private lateinit var receivedContainer: LinearLayout
    private lateinit var receivedHint: TextView

    private val discoveredPeers = mutableListOf<Peer>()
    private val manualPeers = mutableListOf<Peer>()

    private var discovery: Discovery? = null
    private var discoveryStarted = false
    private var screenVisible = false

    private var sending = false
    private var sendingProgress = 0.0
    private var sendingText = ""
    private var sendResult = ""
    private var lastReceiveResult = ""
    private var pendingInstall: ReceivedEntry? = null

    private val client = TransferClient()
    private val store by lazy { MediaStoreStore(this) }
    private val handler = Handler(Looper.getMainLooper())
    private val runtimeListener: () -> Unit = {
        refreshRuntime()
        refreshTransferUi()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()

        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFICATIONS)
        }

        startForegroundService(Intent(this, ReceiverService::class.java))
        ReceiverRuntime.addListener(runtimeListener)
        refreshRuntime()
        refreshReceived()
        handleIncomingIntent(intent)
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        screenVisible = true
        if (ReceiverRuntime.port > 0) startDiscovery(ReceiverRuntime.port)
        refreshRuntime()
        refreshReceived()
        // 从「安装未知应用」设置页返回：已授权就接着装，未授权则明确告知
        pendingInstall?.let { entry ->
            pendingInstall = null
            if (packageManager.canRequestPackageInstalls()) {
                launchInstaller(entry)
            } else {
                toast("尚未允许安装未知应用")
            }
        }
    }

    override fun onPause() {
        super.onPause()
        screenVisible = false
        // 选文件时 Activity 会 pause，但发现要继续跑：
        // 否则选完文件立刻发送时设备列表还没恢复，会误报“没有可用设备”。
    }

    override fun onDestroy() {
        ReceiverRuntime.removeListener(runtimeListener)
        stopDiscovery()
        super.onDestroy()
    }

    // MARK: - UI 构建

    private fun buildUi() {
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(BG)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(32))
        }
        scroll.addView(root)

        root.addView(TextView(this).apply {
            text = "MoonDrop"
            textSize = 30f
            setTextColor(TEXT)
            typeface = Typeface.DEFAULT_BOLD
        })
        root.addView(TextView(this).apply {
            text = "在局域网内与 Mac / 手机互传文件"
            textSize = 13f
            setTextColor(SECONDARY)
            setPadding(0, dp(4), 0, dp(22))
        })

        root.addView(sectionTitle("本机"))
        val localCard = card()
        localName = TextView(this).apply {
            textSize = 17f
            setTextColor(TEXT)
            typeface = Typeface.DEFAULT_BOLD
        }
        localPort = TextView(this).apply {
            textSize = 13f
            setTextColor(SECONDARY)
            setPadding(0, dp(3), 0, 0)
        }
        localCard.addView(localName)
        localCard.addView(localPort)
        root.addView(localCard, cardParams())

        root.addView(sectionTitle("附近的设备"))
        val peersCard = card()
        peersContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        peersCard.addView(peersContainer)
        peersCard.addView(Button(this).apply {
            text = "手动添加设备…"
            textSize = 13f
            setTextColor(ACCENT)
            background = null
            gravity = Gravity.START
            setPadding(0, dp(8), 0, 0)
            setOnClickListener { showManualDialog() }
        })
        root.addView(peersCard, cardParams())

        pendingCard = card()
        pendingCard.visibility = View.GONE
        pendingTitle = TextView(this).apply {
            textSize = 14f
            setTextColor(TEXT)
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, 0, 0, dp(8))
        }
        pendingSendButton = Button(this).apply {
            setOnClickListener { sendPending() }
        }
        val pendingCancel = Button(this).apply {
            text = "取消"
            setOnClickListener {
                pendingUris.clear()
                updatePendingUi()
            }
        }
        pendingCard.addView(pendingTitle)
        pendingCard.addView(pendingSendButton)
        pendingCard.addView(pendingCancel)
        root.addView(pendingCard, cardParams())

        root.addView(sectionTitle("发送"))
        val sendCard = card()
        sendHint = TextView(this).apply {
            textSize = 13f
            setTextColor(SECONDARY)
            setPadding(0, 0, 0, dp(8))
        }
        sendFileButton = Button(this).apply {
            text = "选择文件发送"
            setOnClickListener { pickFiles() }
        }
        sendFolderButton = Button(this).apply {
            text = "选择文件夹发送"
            setOnClickListener { pickFolder() }
        }
        sendCard.addView(sendHint)
        sendCard.addView(sendFileButton)
        sendCard.addView(sendFolderButton)
        root.addView(sendCard, cardParams())

        transferCard = card()
        transferCard.visibility = View.GONE
        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = 0
        }
        transferStatus = TextView(this).apply {
            textSize = 13f
            setTextColor(SECONDARY)
            setPadding(0, dp(6), 0, 0)
        }
        transferCard.addView(progressBar)
        transferCard.addView(transferStatus)
        root.addView(transferCard, cardParams())

        root.addView(sectionTitle("已接收"))
        val receivedCard = card()
        receivedHint = TextView(this).apply {
            text = "暂无接收文件"
            textSize = 13f
            setTextColor(SECONDARY)
        }
        receivedContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        receivedCard.addView(receivedHint)
        receivedCard.addView(receivedContainer)
        root.addView(receivedCard, cardParams())

        root.addView(TextView(this).apply {
            text = "收到的文件保存在「下载 / 来自另一台Mac」。接收服务在前台通知中运行，切到后台也能继续接收。"
            textSize = 12f
            setTextColor(SECONDARY)
            setPadding(0, dp(2), 0, 0)
        })

        setContentView(scroll)
        refreshPeers()
    }

    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable().apply {
            setColor(Color.WHITE)
            cornerRadius = dp(16).toFloat()
        }
        setPadding(dp(16), dp(14), dp(16), dp(14))
        elevation = dp(1).toFloat()
    }

    private fun cardParams() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { bottomMargin = dp(18) }

    private fun sectionTitle(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 12f
        setTextColor(SECONDARY)
        letterSpacing = 0.08f
        setPadding(dp(4), 0, 0, dp(7))
    }

    // MARK: - 状态刷新

    private fun refreshRuntime() {
        val port = ReceiverRuntime.port
        localName.text = DeviceIdentity.name()
        localPort.text = if (port > 0) "监听端口 $port" else "接收服务启动中…"
        if (port > 0 && screenVisible) startDiscovery(port)

        if (ReceiverRuntime.lastResult.isNotEmpty() &&
            ReceiverRuntime.lastResult != lastReceiveResult
        ) {
            lastReceiveResult = ReceiverRuntime.lastResult
            refreshReceived()
        }
        refreshTransferUi()
    }

    private fun refreshTransferUi() {
        when {
            ReceiverRuntime.receiving -> {
                transferCard.visibility = View.VISIBLE
                progressBar.progress = (ReceiverRuntime.progress * 100).toInt()
                transferStatus.text = ReceiverRuntime.statusText
            }
            sending -> {
                transferCard.visibility = View.VISIBLE
                progressBar.progress = (sendingProgress * 100).toInt()
                transferStatus.text = sendingText
            }
            ReceiverRuntime.lastResult.isNotEmpty() -> {
                transferCard.visibility = View.VISIBLE
                progressBar.progress = 100
                transferStatus.text = ReceiverRuntime.lastResult
            }
            sendResult.isNotEmpty() -> {
                transferCard.visibility = View.VISIBLE
                progressBar.progress = 100
                transferStatus.text = sendResult
            }
            else -> transferCard.visibility = View.GONE
        }
        refreshSendState()
    }

    private fun refreshPeers() {
        val peers = mergedPeers()

        peersContainer.removeAllViews()
        if (peers.isEmpty()) {
            peersContainer.addView(TextView(this).apply {
                text = "未发现设备。确认对端已打开 MoonDrop，并处于同一 Wi-Fi。"
                textSize = 13f
                setTextColor(SECONDARY)
                setPadding(0, dp(4), 0, dp(4))
            })
        } else {
            peers.forEachIndexed { index, peer ->
                if (index > 0) {
                    peersContainer.addView(View(this).apply {
                        setBackgroundColor(DIVIDER)
                        layoutParams = LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT, dp(1)
                        )
                    })
                }
                peersContainer.addView(peerRow(peer))
            }
        }
        refreshSendState()
    }

    private fun peerRow(peer: Peer): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(11), dp(10), dp(11))
        }

        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(TextView(this).apply {
            text = peer.name
            textSize = 15f
            setTextColor(TEXT)
            typeface = Typeface.DEFAULT_BOLD
        })
        column.addView(TextView(this).apply {
            text = if (peer.manual) "${peer.host}:${peer.port} · 手动" else "${peer.host}:${peer.port}"
            textSize = 12f
            setTextColor(SECONDARY)
        })
        row.addView(column, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        return row
    }

    private fun refreshSendState() {
        val peers = mergedPeers()
        sendHint.text = if (peers.isEmpty()) {
            "没有可用设备"
        } else {
            "选择文件后会让你选择目标设备"
        }
        val enabled = peers.isNotEmpty() && !sending
        sendFileButton.isEnabled = enabled
        sendFolderButton.isEnabled = enabled
        updatePendingUi()
    }

    // MARK: - 其他 App 分享 / 打开

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val uris = extractIncomingUris(intent)
        if (uris.isEmpty()) return
        com.macdrop.mobile.net.MobileLog.write(
            "收到外部文件 ${uris.size} 个：${uris.joinToString { it.lastPathSegment ?: "?" }}"
        )
        pendingUris.clear()
        pendingUris.addAll(uris)
        updatePendingUi()
    }

    @Suppress("DEPRECATION")
    private fun extractIncomingUris(intent: Intent): List<Uri> {
        val result = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableExtra(Intent.EXTRA_STREAM)
                }
                if (uri != null) result.add(uri)
            }

            Intent.ACTION_SEND_MULTIPLE -> {
                val list = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                } else {
                    intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
                }
                if (list != null) result.addAll(list)
            }

            Intent.ACTION_VIEW -> intent.data?.let { result.add(it) }
        }

        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                result.add(clip.getItemAt(index).uri)
            }
        }

        return result.filter { it.scheme == "content" || it.scheme == "file" }.distinct()
    }

    private fun updatePendingUi() {
        if (!::pendingCard.isInitialized) return
        if (pendingUris.isEmpty()) {
            pendingCard.visibility = View.GONE
            return
        }
        pendingCard.visibility = View.VISIBLE
        pendingTitle.text = "待发送 ${pendingUris.size} 个文件，尚未发送"
        pendingSendButton.text = "选择设备并发送"
        pendingSendButton.isEnabled = mergedPeers().isNotEmpty() && !sending
    }

    private fun sendPending() {
        if (pendingUris.isEmpty() || sending) return
        prepareAndSend(pendingUris.toList(), null, fromPending = true)
    }

    private fun mergedPeers(): List<Peer> {
        val map = LinkedHashMap<String, Peer>()
        for (peer in discoveredPeers) map[peer.endpoint] = peer
        for (peer in manualPeers) if (!map.containsKey(peer.endpoint)) map[peer.endpoint] = peer
        return map.values.sortedBy { it.name.lowercase(Locale.getDefault()) }
    }

    // MARK: - 发现

    private fun startDiscovery(port: Int) {
        if (discoveryStarted) return
        discoveryStarted = true
        val instance = Discovery(this, DeviceIdentity.id(this))
        instance.onPeersChanged = { peers ->
            runOnUiThread {
                discoveredPeers.clear()
                discoveredPeers.addAll(peers)
                refreshPeers()
            }
        }
        instance.start(port)
        discovery = instance
    }

    private fun stopDiscovery() {
        discovery?.stop()
        discovery = null
        discoveryStarted = false
        discoveredPeers.clear()
        refreshPeers()
    }

    // MARK: - 手动添加

    private fun showManualDialog() {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(8), dp(20), 0)
        }
        val hostInput = EditText(this).apply {
            hint = "IP 地址，例如 192.168.1.20"
            inputType = InputType.TYPE_CLASS_TEXT
        }
        val portInput = EditText(this).apply {
            hint = "端口"
            setText("52345")
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        val nameInput = EditText(this).apply { hint = "备注名（可选）" }
        layout.addView(hostInput)
        layout.addView(portInput)
        layout.addView(nameInput)

        AlertDialog.Builder(this)
            .setTitle("手动添加设备")
            .setView(layout)
            .setPositiveButton("连接") { _, _ ->
                val host = hostInput.text.toString().trim()
                val port = portInput.text.toString().toIntOrNull() ?: 52345
                val name = nameInput.text.toString().trim()
                if (host.isEmpty()) {
                    toast("请填写 IP 地址")
                } else {
                    connectManual(host, port, name)
                }
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun connectManual(host: String, port: Int, name: String) {
        thread(name = "macdrop-ping") {
            try {
                val connection = URL(
                    "http://${NetUtil.formatHost(host)}:$port/macdrop/ping"
                ).openConnection() as HttpURLConnection
                connection.connectTimeout = 3_000
                connection.readTimeout = 3_000
                val code = connection.responseCode
                if (code != 200) throw IllegalStateException("HTTP $code")
                val text = connection.inputStream.bufferedReader().use { it.readText() }
                val reported = JSONObject(text).optString("device", host)
                val peer = Peer(
                    name = name.ifEmpty { reported },
                    host = host,
                    port = port,
                    manual = true
                )
                runOnUiThread {
                    manualPeers.removeAll { it.host == host && it.port == port }
                    manualPeers.add(peer)
                    refreshPeers()
                    toast("已添加 ${peer.name}")
                }
            } catch (_: Exception) {
                runOnUiThread { toast("连不上 $host:$port，确认对端在运行且在同一局域网") }
            }
        }
    }

    // MARK: - 发送

    private fun pickFiles() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra(
                DocumentsContract.EXTRA_INITIAL_URI,
                Uri.parse("content://com.android.externalstorage.documents/document/primary%3ADownload")
            )
        }
        startActivityForResult(intent, REQ_FILES)
    }

    private fun pickFolder() {
        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_FOLDER)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        com.macdrop.mobile.net.MobileLog.write(
            "选择返回 req=$requestCode result=$resultCode hasData=${data != null}"
        )
        if (resultCode != RESULT_OK) return

        when (requestCode) {
            REQ_FILES -> {
                val uris = mutableListOf<Uri>()
                data?.clipData?.let { clip ->
                    for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
                }
                data?.data?.let { uri -> if (uris.isEmpty()) uris.add(uri) }
                if (uris.isNotEmpty()) {
                    persistPermissions(uris)
                    prepareAndSend(uris, null)
                }
            }

            REQ_FOLDER -> data?.data?.let { tree ->
                try {
                    contentResolver.takePersistableUriPermission(
                        tree, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {
                }
                prepareAndSend(listOf(tree), tree)
            }
        }
    }

    private fun persistPermissions(uris: List<Uri>) {
        for (uri in uris) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
            }
        }
    }

    private fun prepareAndSend(uris: List<Uri>, tree: Uri?, fromPending: Boolean = false) {
        thread(name = "macdrop-prepare") {
            try {
                val files = if (tree != null) {
                    collectFolder(tree)
                } else {
                    uris.mapNotNull { resolveFile(it) }
                }
                runOnUiThread {
                    if (files.isEmpty()) {
                        toast("没有可发送的文件")
                    } else {
                        presentDeviceChooser(
                            files,
                            fromPending,
                            if (fromPending) uris else emptyList()
                        )
                    }
                }
            } catch (error: Exception) {
                runOnUiThread { toast("读取失败：${error.message}") }
            }
        }
    }

    private fun presentDeviceChooser(
        files: List<OutgoingFile>,
        fromPending: Boolean,
        restoreUris: List<Uri> = emptyList(),
        attempt: Int = 0,
        lastCount: Int = -1
    ) {
        if (isFinishing || isDestroyed) return
        val peers = mergedPeers()

        // 设备可能在暂停/恢复后陆续解析出来：等列表数量稳定再弹，
        // 避免只解析到一台时就把选择器弹出来。
        if (peers.isEmpty()) {
            if (attempt < 4) {
                handler.postDelayed({
                    presentDeviceChooser(files, fromPending, restoreUris, attempt + 1, 0)
                }, 500)
                return
            }
            toast("没有可用设备")
            return
        }
        if (peers.size != lastCount && attempt < 6) {
            handler.postDelayed({
                presentDeviceChooser(files, fromPending, restoreUris, attempt + 1, peers.size)
            }, 500)
            return
        }

        val labels = peers.map { "${it.name}  (${it.host}:${it.port})" }.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("发送到哪台设备？")
            .setItems(labels) { _, which ->
                if (fromPending) {
                    pendingUris.clear()
                    updatePendingUi()
                }
                startSend(files, peers[which], restoreUris)
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun resolveFile(uri: Uri): OutgoingFile? {
        var name = uri.lastPathSegment?.substringAfterLast('/') ?: "file"
        var size = 0L
        try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                        name = cursor.getString(nameIndex) ?: name
                    }
                    val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                        size = cursor.getLong(sizeIndex)
                    }
                }
            }
        } catch (_: Exception) {
        }
        if (size <= 0) size = lengthOf(uri)
        val safe = NetUtil.sanitizeName(name)
        return OutgoingFile(uri, safe, safe, size)
    }

    private fun collectFolder(treeUri: Uri): List<OutgoingFile> {
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootName = documentName(treeUri, rootId)
        val output = mutableListOf<OutgoingFile>()

        fun walk(parentId: String, prefix: String) {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE
            )
            contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val docId = cursor.getString(0) ?: continue
                    val name = NetUtil.sanitizeName(cursor.getString(1) ?: "file")
                    val mime = cursor.getString(2) ?: ""
                    val declaredSize = if (cursor.isNull(3)) 0L else cursor.getLong(3)

                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        walk(docId, "$prefix/$name")
                    } else {
                        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                        val size = if (declaredSize > 0) declaredSize else lengthOf(uri)
                        output.add(OutgoingFile(uri, name, "$prefix/$name", size))
                    }
                }
            }
        }

        walk(rootId, rootName)
        return output
    }

    private fun documentName(treeUri: Uri, documentId: String): String {
        val uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId)
        try {
            contentResolver.query(uri,
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    return NetUtil.sanitizeName(cursor.getString(0) ?: "文件夹")
                }
            }
        } catch (_: Exception) {
        }
        return "文件夹"
    }

    private fun lengthOf(uri: Uri): Long {
        return try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.coerceAtLeast(0)
            } ?: 0
        } catch (_: Exception) {
            0
        }
    }

    private fun startSend(files: List<OutgoingFile>, peer: Peer, restoreUris: List<Uri> = emptyList()) {
        if (sending) return

        sending = true
        sendingProgress = 0.0
        sendingText = "准备发送…"
        sendResult = ""
        refreshTransferUi()

        client.send(
            files = files,
            peer = peer,
            resolver = contentResolver,
            cacheDir = cacheDir,
            onProgress = { sent, total, name ->
                runOnUiThread {
                    // 并发时回调可能乱序到达，进度只增不减
                    val fraction = if (total > 0) sent.toDouble() / total else 0.0
                    sendingProgress = maxOf(sendingProgress, fraction)
                    sendingText = "发送中 ${(sendingProgress * 100).toInt()}% · $name"
                    refreshTransferUi()
                }
            },
            onComplete = { result ->
                runOnUiThread {
                    sending = false
                    sendingProgress = 0.0
                    sendingText = ""
                    sendResult = result.fold(
                        onSuccess = { "已发送 ${files.size} 个文件到 ${peer.name}" },
                        onFailure = {
                            com.macdrop.mobile.net.MobileLog.write("发送失败：${it.message}")
                            // 失败时把待发送的文件放回去，用户可以直接重试
                            if (restoreUris.isNotEmpty()) {
                                pendingUris.addAll(0, restoreUris)
                                updatePendingUi()
                            }
                            "发送失败：${it.message}"
                        }
                    )
                    refreshTransferUi()
                }
            }
        )
    }

    // MARK: - 已接收文件

    private fun refreshReceived() {
        thread(name = "macdrop-received") {
            val items = try {
                store.listReceived()
            } catch (_: Exception) {
                emptyList()
            }
            runOnUiThread { renderReceived(items) }
        }
    }

    private fun renderReceived(items: List<ReceivedEntry>) {
        receivedContainer.removeAllViews()
        receivedHint.visibility = if (items.isEmpty()) View.VISIBLE else View.GONE

        val formatter = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault())
        val swipeRows = mutableListOf<SwipeRowLayout>()
        items.forEachIndexed { index, entry ->
            if (index > 0) {
                receivedContainer.addView(View(this).apply {
                    setBackgroundColor(DIVIDER)
                    layoutParams = LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, dp(1)
                    )
                })
            }
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), dp(10), dp(8), dp(10))
                setBackgroundColor(Color.WHITE)
                isClickable = true
                setOnClickListener { openEntry(entry) }
            }

            val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            column.addView(TextView(this).apply {
                text = entry.name
                textSize = 15f
                setTextColor(TEXT)
                maxLines = 1
            })
            column.addView(TextView(this).apply {
                text = "${NetUtil.formatBytes(entry.size)} · ${formatter.format(Date(entry.modified))}"
                textSize = 12f
                setTextColor(SECONDARY)
                setPadding(0, dp(2), 0, 0)
            })
            row.addView(column, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

            if (isApk(entry)) {
                row.addView(actionLabel("安装", ACCENT) { installApk(entry) })
                row.addView(actionLabel("分享", SECONDARY) { shareEntry(entry) })
            } else {
                row.addView(actionLabel("分享", ACCENT) { shareEntry(entry) })
            }

            val swipeRow = SwipeRowLayout(this).apply {
                setForeground(row)
                onDelete = { deleteEntry(entry) }
                onOpen = { swipeRows.forEach { other -> if (other !== this) other.close() } }
            }
            swipeRows.add(swipeRow)
            receivedContainer.addView(swipeRow)
        }
    }

    private fun openEntry(entry: ReceivedEntry) {
        if (isApk(entry)) {
            installApk(entry)
            return
        }
        val mime = contentResolver.getType(entry.uri) ?: "*/*"
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(entry.uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            toast("没有可打开此文件的应用")
            shareEntry(entry)
        } catch (_: Exception) {
            toast("文件不可用，可能已被移动或删除")
            refreshReceived()
        }
    }

    // MARK: - 安装 APK

    private fun actionLabel(label: String, color: Int, action: () -> Unit): TextView =
        TextView(this).apply {
            text = label
            textSize = 13f
            setTextColor(color)
            setPadding(dp(12), dp(8), dp(12), dp(8))
            isClickable = true
            setOnClickListener { action() }
        }

    private fun isApk(entry: ReceivedEntry): Boolean =
        entry.name.endsWith(".apk", ignoreCase = true)

    private fun installApk(entry: ReceivedEntry) {
        if (!packageManager.canRequestPackageInstalls()) {
            pendingInstall = entry
            AlertDialog.Builder(this)
                .setTitle("需要安装权限")
                .setMessage("系统默认禁止应用安装 APK。请在设置中允许 MoonDrop「安装未知应用」，返回后会自动继续安装。")
                .setPositiveButton("去设置") { _, _ -> openInstallPermissionSettings() }
                .setNegativeButton("取消") { _, _ -> pendingInstall = null }
                .setOnCancelListener { pendingInstall = null }
                .show()
            return
        }
        launchInstaller(entry)
    }

    private fun launchInstaller(entry: ReceivedEntry) {
        // ACTION_INSTALL_PACKAGE 只由系统安装器处理，避免 ACTION_VIEW 弹出
        // 包含 MoonDrop 自己的「打开方式」选择框
        val installer = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setDataAndType(entry.uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(installer)
        } catch (_: ActivityNotFoundException) {
            launchViewInstaller(entry)
        } catch (_: Exception) {
            toast("安装包不可用，可能已被移动或删除")
            pendingInstall = null
            refreshReceived()
        }
    }

    /** 个别 ROM 不响应 ACTION_INSTALL_PACKAGE 时，退回到系统安装器的 VIEW 入口 */
    private fun launchViewInstaller(entry: ReceivedEntry) {
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(entry.uri, APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val handlers = packageManager.queryIntentActivities(view, 0)
            .filter { it.activityInfo.packageName != packageName }
        val target = handlers.firstOrNull {
            it.activityInfo.packageName.contains("packageinstaller", ignoreCase = true)
        } ?: handlers.firstOrNull()
        if (target == null) {
            toast("没有可用的安装程序")
            return
        }
        view.setClassName(target.activityInfo.packageName, target.activityInfo.name)
        try {
            startActivity(view)
        } catch (_: Exception) {
            toast("没有可用的安装程序")
        }
    }

    private fun openInstallPermissionSettings() {
        val packageUri = Uri.parse("package:$packageName")
        try {
            startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, packageUri))
            return
        } catch (_: ActivityNotFoundException) {
        }
        try {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri))
        } catch (_: ActivityNotFoundException) {
            pendingInstall = null
            toast("请手动在系统设置中允许安装未知应用")
        }
    }

    private fun shareEntry(entry: ReceivedEntry) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = contentResolver.getType(entry.uri) ?: "*/*"
            putExtra(Intent.EXTRA_STREAM, entry.uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, "分享文件"))
    }

    private fun deleteEntry(entry: ReceivedEntry) {
        thread(name = "macdrop-delete") {
            store.delete(entry)
            runOnUiThread { refreshReceived() }
        }
    }

    // MARK: - 小工具

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val REQ_FILES = 1001
        private const val REQ_FOLDER = 1002
        private const val REQ_NOTIFICATIONS = 1003
        private const val APK_MIME = "application/vnd.android.package-archive"

        private val BG = Color.parseColor("#F5F6F8")
        private val TEXT = Color.parseColor("#111827")
        private val SECONDARY = Color.parseColor("#6B7280")
        private val ACCENT = Color.parseColor("#1565C0")
        private val DIVIDER = Color.parseColor("#EEF0F3")
    }
}
