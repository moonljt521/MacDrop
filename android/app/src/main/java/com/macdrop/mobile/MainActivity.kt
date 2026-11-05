package com.macdrop.mobile

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import android.text.InputType
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsetsController
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.macdrop.mobile.net.Discovery
import com.macdrop.mobile.net.NetUtil
import com.macdrop.mobile.net.OutgoingFile
import com.macdrop.mobile.net.Peer
import com.macdrop.mobile.net.ReceiverRuntime
import com.macdrop.mobile.net.SubnetScan
import com.macdrop.mobile.net.TransferClient
import com.macdrop.mobile.store.GallerySettings
import com.macdrop.mobile.store.MediaStoreStore
import com.macdrop.mobile.store.ReceivedEntry
import com.macdrop.mobile.store.SentRecord
import com.macdrop.mobile.store.SentStore
import com.macdrop.mobile.ui.MoonButton
import com.macdrop.mobile.ui.MoonProgressView
import com.macdrop.mobile.ui.MoonSegmented
import com.macdrop.mobile.ui.MoonSheet
import com.macdrop.mobile.ui.MoonSwitch
import com.macdrop.mobile.ui.MoonUi
import com.macdrop.mobile.ui.moonCard
import com.macdrop.mobile.ui.moonDivider
import com.macdrop.mobile.ui.moonEmptyState
import com.macdrop.mobile.ui.moonIcon
import com.macdrop.mobile.ui.moonIconButton
import com.macdrop.mobile.ui.moonIconTile
import com.macdrop.mobile.ui.moonPill
import com.macdrop.mobile.ui.moonRippleBackground
import com.macdrop.mobile.ui.moonRounded
import com.macdrop.mobile.ui.moonSectionHeader
import com.macdrop.mobile.ui.moonText
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : Activity() {

    private lateinit var ui: MoonUi
    private lateinit var scrollView: ScrollView

    private lateinit var headerStatusHost: FrameLayout
    private lateinit var heroName: TextView
    private lateinit var heroMeta: TextView
    private lateinit var heroStatusDot: View
    private lateinit var heroStatusText: TextView
    private lateinit var autoSaveSwitch: MoonSwitch
    private lateinit var batteryValue: TextView
    private lateinit var batteryRow: LinearLayout

    private lateinit var sendHint: TextView
    private lateinit var sendFileButton: LinearLayout
    private lateinit var sendAlbumButton: LinearLayout

    private lateinit var peersContainer: LinearLayout
    private lateinit var peersCount: TextView

    private lateinit var transferCard: LinearLayout
    private lateinit var transferIcon: ImageView
    private lateinit var transferTitle: TextView
    private lateinit var transferPercent: TextView
    private lateinit var transferProgress: MoonProgressView
    private lateinit var transferDetail: TextView
    private lateinit var transferWarn: TextView

    private lateinit var pendingCard: LinearLayout
    private lateinit var pendingTitle: TextView
    private lateinit var pendingSendButton: MoonButton
    private val pendingUris = mutableListOf<Uri>()

    private lateinit var historySegmented: MoonSegmented
    private lateinit var historyContainer: LinearLayout
    private lateinit var historyClear: TextView
    private var showReceivedHistory = true


    private var targetPeer: Peer? = null
    private var sendingName = ""
    private var sendingLargeFile = false
    private var displayResult = ""
    private var displayResultTitle = ""
    private var displayResultIsError = false
    private var resultToken = 0

    private val sentRecords = mutableListOf<SentRecord>()
    private val receivedItems = mutableListOf<ReceivedEntry>()

    private val discoveredPeers = mutableListOf<Peer>()
    private val manualPeers = mutableListOf<Peer>()
    private val scannedPeers = mutableListOf<Peer>()

    private var discovery: Discovery? = null
    private var discoveryStarted = false
    private var screenVisible = false
    private var scanning = false

    private var sending = false
    private var sendingProgress = 0.0
    private var lastReceiveResult = ""
    private var pendingInstall: ReceivedEntry? = null
    private var autoPickerArmed = false
    private var chooserVisible = false

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
        refreshSent()
        clearOutgoingCache()
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
        maybeAutoPresent()
        updateBatteryHint()
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
        ui = MoonUi(this)
        val c = ui.colors

        scrollView = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(c.canvas)
            clipToPadding = true
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(20), ui.dp(8), ui.dp(20), ui.dp(28))
        }
        scrollView.addView(root)
        scrollView.setOnApplyWindowInsetsListener { view, insets ->
            view.setPadding(
                0,
                insets.systemWindowInsetTop,
                0,
                insets.systemWindowInsetBottom + ui.dp(8)
            )
            insets
        }

        // 顶部品牌栏
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(moonIconTile(ui, R.drawable.ic_moon_moon, 40, 22, radiusDp = 13))
        val brand = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        brand.addView(moonText(ui, "MoonDrop", 20f, c.textPrimary, ui.medium))
        brand.addView(moonText(ui, "局域网互传 · 无需登录", 12f, c.textSecondary).apply {
            setPadding(0, ui.dp(2), 0, 0)
        })
        header.addView(brand, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply {
            leftMargin = ui.dp(12)
        })
        headerStatusHost = FrameLayout(this)
        header.addView(headerStatusHost, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        root.addView(header)

        // 本机
        val localCard = moonCard(ui).apply {
            layoutParams = blockParams(top = 18)
        }
        val localTop = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        localTop.addView(moonIconTile(ui, R.drawable.ic_moon_phone, 44, 22, radiusDp = 14))
        val localNames = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        heroName = moonText(ui, "", 22f, c.textPrimary, ui.bold, maxLines = 1)
        heroMeta = moonText(ui, "", 12f, c.textSecondary, maxLines = 1).apply {
            setPadding(0, ui.dp(3), 0, 0)
        }
        localNames.addView(heroName)
        localNames.addView(heroMeta)
        localTop.addView(localNames, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ).apply { leftMargin = ui.dp(12) })
        localTop.addView(moonIconButton(ui, R.drawable.ic_moon_edit, "重命名本机") {
            showRenameDialog()
        })
        localCard.addView(localTop)

        val statusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(4), ui.dp(10), ui.dp(4), ui.dp(10))
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            contentDescription = "连接详情"
            setOnClickListener { showConnectionDetails() }
        }
        heroStatusDot = View(this).apply {
            background = moonRounded(ui, c.textTertiary, 999)
            layoutParams = LinearLayout.LayoutParams(ui.dp(6), ui.dp(6)).apply {
                rightMargin = ui.dp(7)
            }
        }
        heroStatusText = moonText(ui, "接收服务启动中…", 12f, c.textSecondary, maxLines = 1)
        statusRow.addView(heroStatusDot)
        statusRow.addView(heroStatusText, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        statusRow.addView(moonIcon(ui, R.drawable.ic_moon_chevron, 16, c.textTertiary))
        localCard.addView(statusRow)

        localCard.addView(moonDivider(ui).apply {
            (layoutParams as LinearLayout.LayoutParams).topMargin = ui.dp(6)
        })

        autoSaveSwitch = MoonSwitch(this, ui).apply {
            setCheckedSilently(GallerySettings.isEnabled(this@MainActivity))
            contentDescription = "收到的照片自动存入相册"
            onCheckedChange = { GallerySettings.setEnabled(this@MainActivity, it) }
        }
        localCard.addView(settingRow("收到的照片自动存入相册", autoSaveSwitch))

        localCard.addView(moonDivider(ui, 4))

        batteryValue = moonText(ui, "去设置", 13f, c.primaryStrong)
        batteryRow = settingRow("后台接收", LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(batteryValue)
            addView(moonIcon(ui, R.drawable.ic_moon_chevron, 16, c.textTertiary).apply {
                setPadding(ui.dp(4), 0, 0, 0)
            })
        }).apply {
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            setOnClickListener { requestIgnoreBatteryOptimizations() }
        }
        localCard.addView(batteryRow)
        root.addView(localCard)

        // 传输状态
        transferCard = moonCard(ui).apply {
            visibility = View.GONE
            layoutParams = blockParams(top = 12)
        }
        val transferHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        transferIcon = moonIcon(ui, R.drawable.ic_moon_send, 22, c.primary)
        transferTitle = moonText(ui, "正在发送", 13f, c.textSecondary, ui.medium, maxLines = 1)
        transferPercent = moonText(ui, "0%", 24f, c.primaryStrong, ui.bold, maxLines = 1)
        transferHead.addView(transferIcon)
        transferHead.addView(transferTitle, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ).apply { leftMargin = ui.dp(8) })
        transferHead.addView(transferPercent)
        transferCard.addView(transferHead)

        transferProgress = MoonProgressView(this, ui)
        transferCard.addView(transferProgress, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(6)
        ).apply { topMargin = ui.dp(10) })

        transferDetail = moonText(ui, "", 12f, c.textSecondary, maxLines = 2).apply {
            setPadding(0, ui.dp(8), 0, 0)
        }
        transferCard.addView(transferDetail)

        transferWarn = moonText(ui, "大文件传输中，请保持 MoonDrop 在前台", 12f, c.warningText, maxLines = 2)
            .apply {
                setPadding(0, ui.dp(6), 0, 0)
                visibility = View.GONE
            }
        transferCard.addView(transferWarn)
        root.addView(transferCard)

        // 发送
        root.addView(moonSectionHeader(ui, "发送"))
        val sendRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        sendFileButton = sendTile(true, R.drawable.ic_moon_file, "选择文件", "任意格式") {
            pickFiles()
        }
        sendAlbumButton = sendTile(false, R.drawable.ic_moon_album, "从相册发送", "图片和视频") {
            pickFromAlbum()
        }
        sendRow.addView(sendFileButton, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ).apply { rightMargin = ui.dp(6) })
        sendRow.addView(sendAlbumButton, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ).apply { leftMargin = ui.dp(6) })
        root.addView(sendRow)
        sendHint = moonText(ui, "", 12f, c.textSecondary, maxLines = 2).apply {
            setPadding(ui.dp(4), ui.dp(8), ui.dp(4), 0)
        }
        root.addView(sendHint)

        // 附近设备
        val peersTrailing = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        peersCount = moonText(ui, "", 12f, c.textSecondary).apply {
            setPadding(0, 0, ui.dp(2), 0)
        }
        peersTrailing.addView(peersCount)
        peersTrailing.addView(moonIconButton(ui, R.drawable.ic_moon_scan, "扫描局域网设备") {
            scanSubnet()
        })
        peersTrailing.addView(moonIconButton(ui, R.drawable.ic_moon_plus, "手动添加设备") {
            showManualDialog()
        })
        root.addView(moonSectionHeader(ui, "附近设备", peersTrailing))

        val peersCard = moonCard(ui, paddingH = 4, paddingV = 4)
        peersContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        peersCard.addView(peersContainer)
        root.addView(peersCard)

        // 待发送
        pendingCard = moonCard(ui).apply {
            visibility = View.GONE
            background = moonRounded(ui, c.primaryTint, 18)
            layoutParams = blockParams(top = 12)
        }
        val pendingHead = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        pendingHead.addView(moonIconTile(ui, R.drawable.ic_moon_send, 36, 18, radiusDp = 11))
        pendingTitle = moonText(ui, "", 15f, c.textPrimary, ui.medium).apply {
            setPadding(ui.dp(10), 0, 0, 0)
        }
        pendingHead.addView(pendingTitle, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        pendingCard.addView(pendingHead)
        val pendingActions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(12), 0, 0)
        }
        pendingSendButton = MoonButton(this, ui, MoonButton.Style.PRIMARY, "选择设备并发送").apply {
            setOnClickListener { sendPending() }
        }
        pendingActions.addView(pendingSendButton, LinearLayout.LayoutParams(
            0, ui.dp(48), 1f
        ))
        pendingActions.addView(MoonButton(this, ui, MoonButton.Style.GHOST, "取消").apply {
            setOnClickListener {
                pendingUris.clear()
                autoPickerArmed = false
                updatePendingUi()
            }
        }, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ui.dp(48)
        ).apply { leftMargin = ui.dp(8) })
        pendingCard.addView(pendingActions)
        root.addView(pendingCard)

        // 记录
        historyClear = TextView(this).apply {
            text = "清空"
            textSize = 13f
            setTextColor(c.primaryStrong)
            typeface = ui.medium
            setPadding(ui.dp(10), ui.dp(8), ui.dp(4), ui.dp(8))
            background = moonRippleBackground(ui, c.primary)
            isClickable = true
            isFocusable = true
            visibility = View.GONE
            setOnClickListener {
                if (showReceivedHistory) confirmClearReceived() else confirmClearSent()
            }
        }
        root.addView(moonSectionHeader(ui, "记录", historyClear))

        historySegmented = MoonSegmented(
            this, ui, listOf("已发送", "已接收"), initial = 1
        ) { index ->
            showReceivedHistory = index == 1
            renderHistory()
        }
        root.addView(historySegmented, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(36)
        ).apply { bottomMargin = ui.dp(10) })

        val historyCard = moonCard(ui, paddingH = 4, paddingV = 4)
        historyContainer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        historyCard.addView(historyContainer)
        root.addView(historyCard)

        // 帮助入口
        val helpRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(4), ui.dp(10), ui.dp(4), ui.dp(10))
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            setOnClickListener { showHelp() }
        }
        helpRow.addView(moonIconTile(ui, R.drawable.ic_moon_info, 36, 18, radiusDp = 11))
        val helpColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(10), 0, 0, 0)
        }
        helpColumn.addView(moonText(ui, "存储位置与常见问题", 15f, c.textPrimary, ui.medium))
        helpColumn.addView(moonText(ui, "文件保存在哪、看不见设备怎么办", 12f, c.textSecondary).apply {
            setPadding(0, ui.dp(2), 0, 0)
        })
        helpRow.addView(helpColumn, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        helpRow.addView(moonIcon(ui, R.drawable.ic_moon_chevron, 16, c.textTertiary))
        root.addView(moonCard(ui, paddingH = 10, paddingV = 6).apply {
            layoutParams = blockParams(top = 12)
            addView(helpRow)
        })

        root.addView(moonText(ui, "MoonDrop · 局域网直连，不经过云端", 12f, c.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, ui.dp(20), 0, 0)
        })

        setContentView(scrollView)
        applyEdgeToEdge()
        updateBatteryHint()
        refreshPeers()
        renderHistory()
    }

    private fun blockParams(top: Int = 0, bottom: Int = 0) = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        topMargin = ui.dp(top)
        bottomMargin = ui.dp(bottom)
    }

    private fun settingRow(title: String, trailing: View): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(56)
            setPadding(ui.dp(4), 0, 0, 0)
            addView(
                moonText(ui, title, 15f, ui.colors.textPrimary, maxLines = 1),
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            )
            addView(trailing)
        }

    private fun sendTile(
        primary: Boolean,
        iconRes: Int,
        title: String,
        subtitle: String,
        onClick: () -> Unit
    ): LinearLayout {
        val c = ui.colors
        val titleColor = if (primary) c.onPrimary else c.primaryStrong
        val subColor = if (primary) ui.alpha(c.onPrimary, 0.75f) else c.textSecondary
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.START
            minimumHeight = ui.dp(96)
            setPadding(ui.dp(14), ui.dp(14), ui.dp(14), ui.dp(14))
            background = moonRounded(ui, if (primary) c.primary else c.primaryTint, 16)
            foreground = moonRippleBackground(
                ui, if (primary) Color.WHITE else c.primary
            )
            isClickable = true
            isFocusable = true
            addView(moonIcon(ui, iconRes, 24, titleColor))
            addView(moonText(ui, title, 15f, titleColor, ui.medium).apply {
                setPadding(0, ui.dp(10), 0, 0)
            })
            addView(moonText(ui, subtitle, 12f, subColor).apply {
                setPadding(0, ui.dp(2), 0, 0)
            })
            setOnClickListener { onClick() }
        }
    }

    private fun applyEdgeToEdge() {
        val c = ui.colors
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            val light = if (ui.isDark) 0 else (
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
                )
            window.insetsController?.setSystemBarsAppearance(
                light,
                WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            )
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                (if (ui.isDark) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR) or
                (if (ui.isDark) 0 else View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR)
        }
        window.navigationBarDividerColor = c.divider
    }

    private fun renderStatusChrome(port: Int, addresses: List<String>) {
        val c = ui.colors
        val online = port > 0 && addresses.isNotEmpty() && ReceiverRuntime.advertising
        val (label, color) = when {
            port <= 0 -> "启动中" to c.textTertiary
            addresses.isEmpty() -> "未连接局域网" to c.warning
            ReceiverRuntime.advertising -> "在线" to c.success
            else -> "广播未上线" to c.warning
        }
        headerStatusHost.removeAllViews()
        headerStatusHost.addView(moonPill(
            ui,
            label,
            if (online) c.successText else c.textSecondary,
            if (online) c.successTint else c.surfaceMuted,
            dotColor = color
        ))
        heroStatusDot.background = moonRounded(ui, color, 999)
        heroStatusText.text = when {
            port <= 0 -> "接收服务启动中…"
            addresses.isEmpty() -> "未连接局域网，点此查看"
            ReceiverRuntime.advertising -> "在线 · 其他设备可以看到本机"
            else -> "广播未上线，点此查看"
        }
        heroStatusText.setTextColor(if (online) c.textSecondary else c.warningText)
    }

    // MARK: - 状态刷新

    private fun refreshRuntime() {
        if (!::heroName.isInitialized) return
        val port = ReceiverRuntime.port
        val addresses = SubnetScan.localIPv4s()
        heroName.text = DeviceIdentity.name(this)
        heroMeta.text = if (port > 0) {
            "端口 $port · " + (addresses.firstOrNull() ?: "未连接局域网")
        } else {
            "接收服务启动中…"
        }
        renderStatusChrome(port, addresses)
        if (port > 0 && screenVisible) startDiscovery(port)

        if (ReceiverRuntime.lastResult.isNotEmpty() &&
            ReceiverRuntime.lastResult != lastReceiveResult
        ) {
            lastReceiveResult = ReceiverRuntime.lastResult
            val error = lastReceiveResult.contains("失败") || lastReceiveResult.contains("拒绝")
            showResult(
                lastReceiveResult,
                error,
                if (error) "接收失败" else "接收完成"
            )
            refreshReceived()
        }
        refreshTransferUi()
    }

    /// 连接详情弹层用：把「没地址」和「广播没上线」分开说清楚
    private fun networkSummary(port: Int): String {
        if (port <= 0) return "接收服务还在启动，请稍等"
        val addresses = SubnetScan.localIPv4s()
        val addressPart = if (addresses.isEmpty()) {
            "未取得局域网地址，请确认已连接 Wi-Fi"
        } else {
            addresses.joinToString(", ")
        }
        val advertisePart = when {
            ReceiverRuntime.advertising -> "广播已上线"
            ReceiverRuntime.advertiseError.isNotEmpty() -> ReceiverRuntime.advertiseError
            else -> "广播未确认，可改用扫描或手动填写 IP"
        }
        return "$addressPart\n$advertisePart"
    }

    private fun sheetInput(hint: String, value: String = ""): EditText =
        EditText(this).apply {
            this.hint = hint
            setText(value)
            setSelection(editableText.length)
            textSize = 15f
            setTextColor(ui.colors.textPrimary)
            setHintTextColor(ui.colors.textTertiary)
            inputType = InputType.TYPE_CLASS_TEXT
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(12))
            background = moonRounded(ui, ui.colors.surfaceMuted, 12)
            includeFontPadding = false
        }

    private fun sheetPrimaryButton(text: String, onClick: () -> Unit): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, ui.dp(16), 0, 0)
            addView(MoonButton(this@MainActivity, ui, MoonButton.Style.PRIMARY, text).apply {
                setOnClickListener { onClick() }
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(48)
            ))
        }

    private fun showRenameDialog() {
        val sheet = MoonSheet(this, ui, "重命名本机")
        val input = sheetInput("例如 客厅的安卓机", DeviceIdentity.name(this)).apply {
            filters = arrayOf(
                android.text.InputFilter.LengthFilter(DeviceIdentity.MAX_NAME_LENGTH)
            )
        }
        sheet.add(input)
        sheet.add(moonText(
            ui,
            "其他设备的 MoonDrop 列表里显示这个名字，最长 ${DeviceIdentity.MAX_NAME_LENGTH} 个字符。",
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, ui.dp(8), 0, 0) })
        sheet.add(sheetPrimaryButton("保存") {
            renameDevice(input.text.toString())
            sheet.dismiss()
        })
        sheet.show()
        input.requestFocus()
    }

    private fun renameDevice(raw: String) {
        val saved = DeviceIdentity.setName(this, raw)
        refreshRuntime()
        // 广播名是 NSD 注册时定死的，必须让前台服务撤掉旧注册再发一次
        try {
            startService(Intent(this, ReceiverService::class.java)
                .setAction(ReceiverService.ACTION_READVERTISE))
        } catch (_: Exception) {
        }
        toast("已改名为「$saved」")
    }

    private fun scanSubnet() {
        if (scanning) return
        scanning = true
        if (::peersCount.isInitialized) peersCount.text = "扫描中…"
        SubnetScan.run { found ->
            scanning = false
            if (isFinishing || isDestroyed) return@run
            for (hit in found) {
                val peer = Peer(name = hit.name, host = hit.host, port = hit.port, manual = true)
                scannedPeers.removeAll { it.endpoint == peer.endpoint }
                scannedPeers.add(peer)
            }
            refreshPeers()
            toast(if (found.isEmpty()) {
                "没有扫到设备，网络可能开了客户端隔离"
            } else {
                "扫描到 ${found.size} 台设备"
            })
        }
    }

    private fun refreshTransferUi() {
        if (!::transferCard.isInitialized) return
        when {
            sending -> bindActiveTransfer(outgoing = true)
            ReceiverRuntime.receiving -> bindActiveTransfer(outgoing = false)
            displayResult.isNotEmpty() -> bindResultTransfer()
            else -> transferCard.visibility = View.GONE
        }
        refreshSendState()
    }

    private fun bindActiveTransfer(outgoing: Boolean) {
        val c = ui.colors
        transferCard.visibility = View.VISIBLE
        transferIcon.setImageResource(
            if (outgoing) R.drawable.ic_moon_send else R.drawable.ic_moon_download
        )
        transferIcon.setColorFilter(c.primary)
        transferTitle.text = if (outgoing) "正在发送" else "正在接收"
        transferTitle.setTextColor(c.textSecondary)
        val progress = if (outgoing) sendingProgress else ReceiverRuntime.progress
        transferPercent.visibility = View.VISIBLE
        transferPercent.text = "${(progress * 100).toInt()}%"
        transferPercent.setTextColor(c.primaryStrong)
        transferProgress.setProgress(progress.toFloat())
        transferDetail.text = if (outgoing) {
            sendingName.ifEmpty { "准备发送…" }
        } else {
            ReceiverRuntime.statusText.substringAfter("· ", "").ifEmpty { "接收中…" }
        }
        transferWarn.visibility =
            if (outgoing && sendingLargeFile) View.VISIBLE else View.GONE
    }

    private fun bindResultTransfer() {
        val c = ui.colors
        transferCard.visibility = View.VISIBLE
        transferIcon.setImageResource(
            if (displayResultIsError) R.drawable.ic_moon_error else R.drawable.ic_moon_check_circle
        )
        transferIcon.setColorFilter(if (displayResultIsError) c.danger else c.success)
        transferTitle.text = displayResultTitle
        transferTitle.setTextColor(
            if (displayResultIsError) c.dangerText else c.successText
        )
        transferPercent.visibility = View.GONE
        transferProgress.setProgress(if (displayResultIsError) 0f else 1f)
        transferDetail.text = displayResult
        transferWarn.visibility = View.GONE
    }

    private fun showResult(text: String, error: Boolean, title: String) {
        displayResult = text
        displayResultIsError = error
        displayResultTitle = title
        val token = ++resultToken
        handler.postDelayed({
            if (token == resultToken) {
                displayResult = ""
                refreshTransferUi()
            }
        }, if (error) 8_000L else 5_000L)
        refreshTransferUi()
    }

    private fun refreshPeers() {
        if (!::peersContainer.isInitialized) return
        val peers = mergedPeers()
        peersCount.text = if (peers.isEmpty()) "" else "${peers.size} 台"
        peersContainer.removeAllViews()
        if (peers.isEmpty()) {
            peersContainer.addView(moonEmptyState(
                ui,
                R.drawable.ic_moon_scan,
                "还没有发现设备",
                "打开对端 MoonDrop，并连到同一个 Wi-Fi。仍看不见就扫描或手动添加。",
                "扫描局域网"
            ) { scanSubnet() })
        } else {
            peers.forEachIndexed { index, peer ->
                if (index > 0) peersContainer.addView(moonDivider(ui, 56))
                peersContainer.addView(deviceRow(peer) { showSendOptions(peer) })
            }
        }
        refreshSendState()
    }

    private fun deviceRow(peer: Peer, onClick: () -> Unit): LinearLayout {
        val c = ui.colors
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(64)
            setPadding(ui.dp(10), ui.dp(8), ui.dp(10), ui.dp(8))
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            contentDescription = "${peer.name}，${peer.host}:${peer.port}，点按发送文件"
            setOnClickListener { onClick() }
        }
        row.addView(moonIconTile(
            ui,
            if (peer.manual) R.drawable.ic_moon_link else R.drawable.ic_moon_device,
            40,
            20
        ))
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(12), 0, ui.dp(8), 0)
        }
        val nameRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        nameRow.addView(moonText(ui, peer.name, 15f, c.textPrimary, ui.medium, maxLines = 1))
        if (peer.peerToPeer) {
            nameRow.addView(moonText(ui, "点对点", 12f, c.warningText, ui.medium).apply {
                background = moonRounded(ui, c.warningTint, 6)
                setPadding(ui.dp(6), ui.dp(2), ui.dp(6), ui.dp(2))
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { leftMargin = ui.dp(6) })
        }
        column.addView(nameRow)
        val route = when {
            peer.peerToPeer -> "直连，不在同一 Wi-Fi"
            peer.manual -> "手动添加"
            else -> null
        }
        val address = "${peer.host}:${peer.port}"
        column.addView(moonText(
            ui,
            if (route == null) address else "$route · $address",
            12f,
            c.textSecondary,
            maxLines = 1
        ).apply { setPadding(0, ui.dp(2), 0, 0) })
        row.addView(column, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        row.addView(moonIcon(ui, R.drawable.ic_moon_chevron, 16, c.textTertiary))
        return row
    }

    private fun refreshSendState() {
        if (!::sendFileButton.isInitialized) return
        val peers = mergedPeers()
        sendHint.text = when {
            sending -> "正在传输，请稍候"
            peers.isEmpty() -> "先连接一台设备才能发送"
            else -> "选完文件后会让你确认目标设备，也可以直接点设备发送"
        }
        val enabled = peers.isNotEmpty() && !sending
        for (tile in listOf(sendFileButton, sendAlbumButton)) {
            tile.isEnabled = enabled
            tile.isClickable = enabled
            tile.alpha = if (enabled) 1f else 0.4f
        }
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
        // 追加而不是覆盖：上一批失败/未发送的文件不能被新分享冲掉
        val known = pendingUris.map { it.toString() }.toHashSet()
        var added = false
        for (uri in uris) {
            if (known.add(uri.toString())) {
                pendingUris.add(uri)
                added = true
            }
        }
        if (!added) return
        autoPickerArmed = true
        updatePendingUi()
        handler.post { maybeAutoPresent() }
    }

    /// 分享/打开文件后直接弹设备选择，不用再手动点「选择设备并发送」。
    private fun maybeAutoPresent() {
        if (!autoPickerArmed) return
        if (!screenVisible || isFinishing || isDestroyed) return
        if (pendingUris.isEmpty() || sending || chooserVisible) return
        autoPickerArmed = false
        sendPending()
    }

    private fun clearOutgoingCache() {
        try {
            java.io.File(cacheDir, "outgoing").deleteRecursively()
        } catch (_: Exception) {
        }
    }

    /// 锁屏后收不到文件，通常是系统的电池优化把前台服务冻结了。
    private fun updateBatteryHint() {
        if (!::batteryValue.isInitialized) return
        val ignoring = isIgnoringBatteryOptimizations()
        batteryValue.text = if (ignoring) "已允许" else "去设置"
        batteryValue.setTextColor(
            if (ignoring) ui.colors.textSecondary else ui.colors.primaryStrong
        )
        batteryRow.contentDescription = if (ignoring) {
            "后台接收，电池优化已关闭"
        } else {
            "后台接收，点按关闭电池优化"
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(packageName) == true

    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) {
            toast("已允许后台接收")
            return
        }
        val packageUri = Uri.parse("package:$packageName")
        try {
            startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, packageUri))
            return
        } catch (_: ActivityNotFoundException) {
        }
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: ActivityNotFoundException) {
            toast("请在系统设置中关闭 MoonDrop 的电池优化")
        }
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
        pendingTitle.text = "${pendingUris.size} 个文件待发送"
        pendingSendButton.isEnabled = mergedPeers().isNotEmpty() && !sending
    }

    private fun sendPending() {
        if (pendingUris.isEmpty() || sending) return
        prepareAndSend(pendingUris.toList(), fromPending = true)
    }

    private fun showSendOptions(peer: Peer) {
        if (sending) {
            toast("正在传输，请稍候")
            return
        }
        val sheet = MoonSheet(this, ui, "发送到 ${peer.name}")
        sheet.add(moonText(
            ui,
            "${peer.host}:${peer.port}" + if (peer.peerToPeer) " · 点对点直连" else "",
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, 0, 0, ui.dp(4)) })
        sheet.addAction(R.drawable.ic_moon_file, "选择文件") {
            targetPeer = peer
            sheet.dismiss()
            pickFiles()
        }
        sheet.addAction(R.drawable.ic_moon_album, "从相册发送") {
            targetPeer = peer
            sheet.dismiss()
            pickFromAlbum()
        }
        sheet.show()
    }

    private fun takeTargetPeer(): Peer? {
        val peer = targetPeer
        targetPeer = null
        return peer
    }

    private fun showConnectionDetails() {
        val port = ReceiverRuntime.port
        val addresses = SubnetScan.localIPv4s()
        val sheet = MoonSheet(this, ui, "连接详情")
        sheet.add(infoRow("本机名称", DeviceIdentity.name(this)))
        sheet.add(infoRow("监听端口", if (port > 0) port.toString() else "启动中"))
        sheet.add(infoRow(
            "局域网地址",
            addresses.joinToString(", ").ifEmpty { "未连接 Wi-Fi" }
        ))
        sheet.add(infoRow(
            "广播状态",
            when {
                ReceiverRuntime.advertising -> "已上线"
                ReceiverRuntime.advertiseError.isNotEmpty() -> "失败"
                else -> "未确认"
            }
        ))
        sheet.add(moonText(
            ui,
            networkSummary(port),
            13f,
            ui.colors.textSecondary
        ).apply {
            setPadding(0, ui.dp(10), 0, 0)
            setLineSpacing(ui.dpf(3f), 1f)
        })
        sheet.add(sheetPrimaryButton("复制地址") {
            val address = addresses.firstOrNull()
            if (address == null) {
                toast("还没有局域网地址")
            } else {
                copyText("$address:${if (port > 0) port else 52345}")
                toast("已复制地址")
            }
        })
        sheet.show()
    }

    private fun infoRow(label: String, value: String): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(8), 0, ui.dp(8))
            addView(moonText(ui, label, 13f, ui.colors.textSecondary))
            addView(moonText(ui, value, 13f, ui.colors.textPrimary, ui.medium, maxLines = 2).apply {
                gravity = Gravity.END
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }

    private fun copyText(text: String) {
        getSystemService(ClipboardManager::class.java)
            ?.setPrimaryClip(ClipData.newPlainText("MoonDrop", text))
    }

    private fun showHelp() {
        val version = try {
            packageManager.getPackageInfo(packageName, 0).versionName ?: ""
        } catch (_: Exception) {
            ""
        }
        val sheet = MoonSheet(this, ui, "存储位置与常见问题")
        sheet.add(helpHeading("收到的文件放在哪"))
        sheet.add(helpBody(
            "普通文件保存在「下载 / 来自另一台Mac」。\n\n" +
                "开关开启时，图片和视频直接写入「Pictures / MoonDrop」或「Movies / MoonDrop」，" +
                "只保存一份，相册里不会出现重复。关闭开关后媒体留在下载目录，" +
                "可以在记录里点「⋯ → 存入相册」。"
        ))
        sheet.add(helpHeading("看不见设备怎么办"))
        sheet.add(helpBody(
            "确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。Android 设备必须同一 Wi-Fi；" +
                "附近的 Apple 设备即使连着别的网络，也会以「点对点」出现。\n\n" +
                "仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。"
        ))
        sheet.add(helpHeading("后台接收"))
        sheet.add(helpBody(
            "接收服务在前台通知里运行，切到后台也能继续接收。关闭电池优化可以减少锁屏后被系统冻结的情况。"
        ))
        sheet.add(helpHeading("关于"))
        sheet.add(helpBody(
            "MoonDrop ${version.ifEmpty { "1.6.0" }} · 局域网直连，不经过云端。"
        ))
        sheet.show()
    }

    private fun helpHeading(text: String): TextView =
        moonText(ui, text, 13f, ui.colors.primaryStrong, ui.medium).apply {
            setPadding(0, ui.dp(16), 0, ui.dp(4))
        }

    private fun helpBody(text: String): TextView =
        moonText(ui, text, 13f, ui.colors.textSecondary).apply {
            setLineSpacing(ui.dpf(3f), 1f)
        }

    private fun mergedPeers(): List<Peer> {
        val map = LinkedHashMap<String, Peer>()
        for (peer in scannedPeers) map[peer.endpoint] = peer
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
        val sheet = MoonSheet(this, ui, "手动添加设备")
        val hostInput = sheetInput("IP 地址，例如 192.168.1.20")
        val portInput = sheetInput("端口", "52345").apply {
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        val nameInput = sheetInput("备注名（可选）")
        sheet.add(hostInput)
        sheet.add(portInput)
        sheet.add(nameInput)
        sheet.add(moonText(
            ui,
            "对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。",
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, ui.dp(10), 0, 0) })
        sheet.add(sheetPrimaryButton("连接") {
            val host = hostInput.text.toString().trim()
            val port = portInput.text.toString().toIntOrNull() ?: 52345
            val name = nameInput.text.toString().trim()
            if (host.isEmpty()) {
                toast("请填写 IP 地址")
            } else {
                sheet.dismiss()
                connectManual(host, port, name)
            }
        })
        sheet.show()
        hostInput.requestFocus()
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

    /** 从相册选图片/视频发送 */
    private fun pickFromAlbum() {
        val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
        }
        startActivityForResult(intent, REQ_ALBUM)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        com.macdrop.mobile.net.MobileLog.write(
            "选择返回 req=$requestCode result=$resultCode hasData=${data != null}"
        )
        if (resultCode != RESULT_OK) {
            targetPeer = null
            return
        }

        when (requestCode) {
            REQ_FILES -> {
                val uris = mutableListOf<Uri>()
                data?.clipData?.let { clip ->
                    for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
                }
                data?.data?.let { uri -> if (uris.isEmpty()) uris.add(uri) }
                if (uris.isNotEmpty()) {
                    persistPermissions(uris)
                    prepareAndSend(uris, target = takeTargetPeer())
                }
            }

            REQ_ALBUM -> {
                val uris = mutableListOf<Uri>()
                data?.clipData?.let { clip ->
                    for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
                }
                data?.data?.let { uri -> if (uris.isEmpty()) uris.add(uri) }
                if (uris.isNotEmpty()) {
                    prepareAndSend(uris, target = takeTargetPeer())
                }
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

    private fun prepareAndSend(
        uris: List<Uri>,
        fromPending: Boolean = false,
        target: Peer? = null
    ) {
        thread(name = "macdrop-prepare") {
            try {
                val files = uris.mapNotNull { resolveFile(it) }
                runOnUiThread {
                    if (files.isEmpty()) {
                        toast("没有可发送的文件")
                    } else if (target != null) {
                        startSend(files, target)
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
            if (attempt < 6) {
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

        val sheet = MoonSheet(this, ui, "发送到哪台设备？")
        var picked = false
        peers.forEachIndexed { index, peer ->
            if (index > 0) sheet.add(moonDivider(ui, 56))
            sheet.add(deviceRow(peer) {
                picked = true
                if (fromPending) {
                    // 只移除本次真正发送的，弹层期间新分享进来的文件继续保留
                    val sent = restoreUris.toSet()
                    pendingUris.removeAll { it in sent }
                    updatePendingUi()
                }
                sheet.dismiss()
                startSend(files, peer, restoreUris)
            })
        }
        sheet.add(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, ui.dp(12), 0, 0)
            addView(MoonButton(this@MainActivity, ui, MoonButton.Style.GHOST, "取消").apply {
                setOnClickListener { sheet.dismiss() }
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ui.dp(44)
            ))
        })
        sheet.setOnDismissListener {
            chooserVisible = false
            // 用户主动取消后不要在下次回到前台又自动弹出
            if (!picked) autoPickerArmed = false
        }
        chooserVisible = true
        sheet.show()
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

    private fun lengthOf(uri: Uri): Long {
        return try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { descriptor ->
                descriptor.length.coerceAtLeast(0)
            } ?: 0
        } catch (_: Exception) {
            0
        }
    }

    private fun startSend(
        files: List<OutgoingFile>,
        peer: Peer,
        restoreUris: List<Uri> = emptyList()
    ) {
        if (sending) return

        sending = true
        sendingProgress = 0.0
        sendingName = files.firstOrNull()?.name.orEmpty()
        sendingLargeFile = files.sumOf { it.size } > 100L * 1024L * 1024L
        displayResult = ""
        resultToken++
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
                    sendingName = name
                    refreshTransferUi()
                }
            },
            onComplete = { result ->
                runOnUiThread {
                    sending = false
                    sendingProgress = 0.0
                    result.fold(
                        onSuccess = {
                            SentStore.add(
                                this,
                                files.map { file -> file.name },
                                peer.name,
                                files.sumOf { file -> file.size }
                            )
                            refreshSent()
                            showResult(
                                "已发送 ${files.size} 个文件到 ${peer.name}",
                                error = false,
                                title = "发送完成"
                            )
                        },
                        onFailure = {
                            com.macdrop.mobile.net.MobileLog.write("发送失败：${it.message}")
                            // 失败时把待发送的文件放回去，用户可以直接重试
                            if (restoreUris.isNotEmpty()) {
                                val known = pendingUris.map { uri -> uri.toString() }.toHashSet()
                                val restored = restoreUris.filter { known.add(it.toString()) }
                                pendingUris.addAll(0, restored)
                                updatePendingUi()
                            }
                            showResult(
                                "发送失败：${it.message}",
                                error = true,
                                title = "发送失败"
                            )
                        }
                    )
                    clearOutgoingCache()
                    handler.post { maybeAutoPresent() }
                }
            }
        )
    }

    // MARK: - 记录

    private fun refreshSent() {
        sentRecords.clear()
        sentRecords.addAll(SentStore.load(this))
        if (::historySegmented.isInitialized) {
            updateHistoryLabels()
            if (!showReceivedHistory) renderHistory()
        }
    }

    private fun refreshReceived() {
        thread(name = "macdrop-received") {
            val items = try {
                store.listReceived()
            } catch (_: Exception) {
                emptyList()
            }
            runOnUiThread {
                receivedItems.clear()
                receivedItems.addAll(items)
                if (::historySegmented.isInitialized) {
                    updateHistoryLabels()
                    if (showReceivedHistory) renderHistory()
                }
            }
        }
    }

    private fun updateHistoryLabels() {
        historySegmented.setLabel(
            0,
            if (sentRecords.isEmpty()) "已发送" else "已发送 ${sentRecords.size}"
        )
        historySegmented.setLabel(
            1,
            if (receivedItems.isEmpty()) "已接收" else "已接收 ${receivedItems.size}"
        )
    }

    private fun renderHistory() {
        if (!::historyContainer.isInitialized) return
        historyContainer.removeAllViews()
        val hasItems = if (showReceivedHistory) receivedItems.isNotEmpty() else sentRecords.isNotEmpty()
        historyClear.visibility = if (hasItems) View.VISIBLE else View.GONE
        if (showReceivedHistory) renderReceivedItems() else renderSentItems()
    }

    private fun renderSentItems() {
        if (sentRecords.isEmpty()) {
            historyContainer.addView(moonEmptyState(
                ui,
                R.drawable.ic_moon_send,
                "还没有发送记录",
                "发出的文件会按时间出现在这里"
            ))
            return
        }
        var currentDay = ""
        sentRecords.forEachIndexed { index, record ->
            val day = dayLabel(record.date)
            if (day != currentDay) {
                currentDay = day
                historyContainer.addView(groupHeader(day))
            } else if (index > 0) {
                historyContainer.addView(moonDivider(ui, 60))
            }
            historyContainer.addView(sentRow(record))
        }
    }

    private fun sentRow(record: SentRecord): LinearLayout {
        val c = ui.colors
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(64)
            setPadding(ui.dp(10), ui.dp(8), ui.dp(10), ui.dp(8))
        }
        val name = if (record.names.size == 1) record.names[0] else "${record.names.size} 个文件"
        row.addView(moonIconTile(ui, fileIcon(name), 40, 20))
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(12), 0, ui.dp(8), 0)
        }
        column.addView(moonText(ui, name, 15f, c.textPrimary, ui.medium, maxLines = 1))
        column.addView(moonText(
            ui,
            "→ ${record.target} · ${NetUtil.formatBytes(record.size)} · " +
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(record.date)),
            12f,
            c.textSecondary,
            maxLines = 1
        ).apply { setPadding(0, ui.dp(2), 0, 0) })
        row.addView(column, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        row.addView(moonIcon(ui, R.drawable.ic_moon_check, 18, c.success).apply {
            contentDescription = "已发送"
        })
        return row
    }

    private fun renderReceivedItems() {
        if (receivedItems.isEmpty()) {
            historyContainer.addView(moonEmptyState(
                ui,
                R.drawable.ic_moon_folder,
                "还没有接收文件",
                "其他设备发来的文件会出现在这里",
                "刷新"
            ) { refreshReceived() })
            return
        }
        val swipeRows = mutableListOf<SwipeRowLayout>()
        var currentDay = ""
        receivedItems.forEachIndexed { index, entry ->
            val day = dayLabel(entry.modified)
            if (day != currentDay) {
                currentDay = day
                historyContainer.addView(groupHeader(day))
            } else if (index > 0) {
                historyContainer.addView(moonDivider(ui, 60))
            }
            val row = receivedRow(entry)
            val swipeRow = SwipeRowLayout(this).apply {
                setForeground(row)
                onDelete = { deleteEntry(entry) }
                onOpen = { swipeRows.forEach { other -> if (other !== this) other.close() } }
            }
            swipeRows.add(swipeRow)
            historyContainer.addView(swipeRow)
        }
    }

    private fun receivedRow(entry: ReceivedEntry): LinearLayout {
        val c = ui.colors
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(64)
            setPadding(ui.dp(10), ui.dp(8), ui.dp(4), ui.dp(8))
            setBackgroundColor(c.surface)
            isClickable = true
            isFocusable = true
            setOnClickListener { openEntry(entry) }
        }
        row.addView(moonIconTile(ui, fileIcon(entry.name), 40, 20))
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(12), 0, ui.dp(8), 0)
        }
        column.addView(moonText(ui, entry.name, 15f, c.textPrimary, ui.medium, maxLines = 1))
        column.addView(moonText(
            ui,
            "${NetUtil.formatBytes(entry.size)} · " +
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(entry.modified)),
            12f,
            c.textSecondary,
            maxLines = 1
        ).apply { setPadding(0, ui.dp(2), 0, 0) })
        row.addView(column, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f
        ))
        row.addView(moonIconButton(ui, R.drawable.ic_moon_more, "更多操作") {
            showEntryActions(entry)
        })
        return row
    }

    private fun groupHeader(label: String): TextView =
        moonText(ui, label, 12f, ui.colors.textSecondary, ui.medium).apply {
            setPadding(ui.dp(12), ui.dp(12), 0, ui.dp(2))
        }

    private fun dayLabel(timestamp: Long): String {
        val today = Calendar.getInstance()
        val target = Calendar.getInstance().apply { timeInMillis = timestamp }
        if (today.get(Calendar.YEAR) == target.get(Calendar.YEAR) &&
            today.get(Calendar.DAY_OF_YEAR) == target.get(Calendar.DAY_OF_YEAR)
        ) {
            return "今天"
        }
        val yesterday = (today.clone() as Calendar).apply {
            add(Calendar.DAY_OF_YEAR, -1)
        }
        if (yesterday.get(Calendar.YEAR) == target.get(Calendar.YEAR) &&
            yesterday.get(Calendar.DAY_OF_YEAR) == target.get(Calendar.DAY_OF_YEAR)
        ) {
            return "昨天"
        }
        val pattern = if (today.get(Calendar.YEAR) == target.get(Calendar.YEAR)) {
            "M月d日"
        } else {
            "yyyy年M月d日"
        }
        return SimpleDateFormat(pattern, Locale.getDefault()).format(Date(timestamp))
    }

    private fun fileIcon(name: String): Int {
        val ext = name.substringAfterLast('.', "").lowercase(Locale.getDefault())
        return when (ext) {
            "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "svg" ->
                R.drawable.ic_moon_image
            "mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp" -> R.drawable.ic_moon_video
            "mp3", "wav", "m4a", "aac", "flac", "ogg" -> R.drawable.ic_moon_audio
            "apk", "xapk", "apks" -> R.drawable.ic_moon_apk
            "zip", "rar", "7z", "tar", "gz", "bz2" -> R.drawable.ic_moon_archive
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf" ->
                R.drawable.ic_moon_file
            else -> R.drawable.ic_moon_file
        }
    }

    private fun showEntryActions(entry: ReceivedEntry) {
        val sheet = MoonSheet(this, ui, entry.name)
        sheet.addAction(
            if (isApk(entry)) R.drawable.ic_moon_apk else R.drawable.ic_moon_file,
            if (isApk(entry)) "安装" else "打开"
        ) {
            sheet.dismiss()
            openEntry(entry)
        }
        sheet.addAction(R.drawable.ic_moon_share, "分享") {
            sheet.dismiss()
            shareEntry(entry)
        }
        if (GallerySettings.isMedia(entry.name) &&
            !GallerySettings.isInGallery(entry.relativePath)
        ) {
            sheet.addAction(R.drawable.ic_moon_download, "存入相册") {
                sheet.dismiss()
                saveToGallery(entry)
            }
        }
        sheet.addAction(R.drawable.ic_moon_delete, "删除", danger = true) {
            sheet.dismiss()
            deleteEntry(entry)
        }
        sheet.show()
    }

    private fun confirmClearSent() {
        if (sentRecords.isEmpty()) return
        AlertDialog.Builder(this)
            .setTitle("清空发送记录？")
            .setMessage("只清列表，已经发出去的文件不受影响。")
            .setPositiveButton("清空") { _, _ ->
                SentStore.clear(this)
                refreshSent()
            }
            .setNegativeButton("取消", null)
            .show()
    }

    private fun confirmClearReceived() {
        AlertDialog.Builder(this)
            .setTitle("清空已接收？")
            .setMessage("「下载 / 来自另一台Mac」里的文件会被删除，无法恢复。已经存入系统相册的图片和视频会保留在相册里，只是从这个列表移除。")
            .setPositiveButton("删除全部") { _, _ ->
                thread(name = "macdrop-clear") {
                    runCatching { store.clearReceived() }
                    runOnUiThread { refreshReceived() }
                }
            }
            .setNegativeButton("取消", null)
            .show()
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

    // 把下载目录里的媒体移到相册目录；已在相册里的条目由 store 直接判重。
    // 移动后原 URI 失效，所以成功后必须刷新列表。
    private fun saveToGallery(entry: ReceivedEntry) {
        thread(name = "macdrop-gallery") {
            val result = runCatching { store.saveToGallery(entry) }
            runOnUiThread {
                toast(result.fold(
                    onSuccess = { "已存入相册：${entry.name}" },
                    onFailure = { "存入相册失败：${it.message ?: "未知错误"}" }
                ))
                if (result.isSuccess) refreshReceived()
            }
        }
    }

    // MARK: - 小工具

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        private const val REQ_FILES = 1001
        private const val REQ_ALBUM = 1004
        private const val REQ_NOTIFICATIONS = 1003
        private const val APK_MIME = "application/vnd.android.package-archive"
    }
}
