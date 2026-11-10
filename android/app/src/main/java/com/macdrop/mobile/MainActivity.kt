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
import android.os.SystemClock
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
import com.macdrop.mobile.ui.MoonActionButton
import com.macdrop.mobile.ui.MoonCrescentView
import com.macdrop.mobile.ui.MoonNearbyDevice
import com.macdrop.mobile.ui.MoonNearfieldView
import com.macdrop.mobile.ui.MoonButton
import com.macdrop.mobile.ui.MoonPrefs
import com.macdrop.mobile.ui.MoonProgressView
import com.macdrop.mobile.ui.MoonRadarDrawable
import com.macdrop.mobile.ui.MoonSegmented
import com.macdrop.mobile.ui.MoonSheet
import com.macdrop.mobile.ui.MoonStatusDot
import com.macdrop.mobile.ui.MoonStrings
import com.macdrop.mobile.ui.MoonSwitch
import com.macdrop.mobile.ui.MoonTrack
import com.macdrop.mobile.ui.MoonType
import com.macdrop.mobile.ui.MoonUi
import com.macdrop.mobile.ui.moonListRow
import com.macdrop.mobile.ui.moonPanel
import com.macdrop.mobile.ui.moonDivider
import com.macdrop.mobile.ui.moonEmptyState
import com.macdrop.mobile.ui.moonIcon
import com.macdrop.mobile.ui.moonIconButton
import com.macdrop.mobile.ui.moonRipple
import com.macdrop.mobile.ui.moonRippleBackground
import com.macdrop.mobile.ui.moonRounded
import com.macdrop.mobile.ui.moonSectionLabel
import com.macdrop.mobile.ui.moonText
import com.macdrop.mobile.ui.moonTopBar
import com.macdrop.mobile.ui.tracked
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

    private lateinit var localStatusRow: LinearLayout
    private lateinit var heroName: TextView
    private lateinit var heroStatusDot: MoonStatusDot
    private lateinit var heroStatusText: TextView
    private lateinit var autoSaveSwitch: MoonSwitch
    private lateinit var batteryValue: TextView
    private lateinit var batteryRow: LinearLayout

    private lateinit var sendHint: TextView
    private lateinit var sendFileButton: MoonActionButton
    private lateinit var sendAlbumButton: MoonActionButton

    private lateinit var nearfield: MoonNearfieldView
    private lateinit var peersCount: TextView
    private lateinit var recentDetail: TextView
    private lateinit var recentRow: LinearLayout

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

    // These views belong only to the currently presented history sheet.
    private var historySheet: MoonSheet? = null
    private var historySegmented: MoonSegmented? = null
    private var historyContainer: LinearLayout? = null
    private var historyHost: LinearLayout? = null
    private var historyClear: TextView? = null
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
    private var receivedRefreshToken = 0

    private val discoveredPeers = mutableListOf<Peer>()
    private val manualPeers = mutableListOf<Peer>()
    private val scannedPeers = mutableListOf<Peer>()

    private var discovery: Discovery? = null
    private var discoveryStarted = false
    private var screenVisible = false
    private var scanning = false
    /** 本次扫描已经命中的设备数 */
    private var scanFound = 0
    /** 扫描开始时刻：用来保证雷达至少被看见一小会儿 */
    private var scanStartedAt = 0L
    private lateinit var rescanButton: MoonButton
    private var radarDrawable: MoonRadarDrawable? = null

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

    override fun attachBaseContext(newBase: Context) {
        // 语言/外观必须在 Activity 挂上 base 之前生效，资源和主题才会跟着换
        MoonPrefs.init(newBase)
        MoonStrings.language = MoonPrefs.language
        super.attachBaseContext(MoonPrefs.wrap(newBase))
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
                toast(MoonStrings.t("尚未允许安装未知应用"))
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
        historySheet?.dismiss()
        stopDiscovery()
        super.onDestroy()
    }

    // MARK: - UI 构建

    private fun buildUi() {
        ui = MoonUi(this)
        val c = ui.colors
        val configuration = resources.configuration
        val stackActions = configuration.screenWidthDp < 340 ||
            configuration.screenWidthDp / configuration.fontScale < 260
        val compactHeight = configuration.screenHeightDp < 480 || configuration.fontScale >= 1.8f
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(c.canvas)
            setOnApplyWindowInsetsListener { view, insets ->
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
                insets
            }
        }
        scrollView = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(22), ui.dp(8), ui.dp(22), ui.dp(8))
        }
        scrollView.addView(content)
        root.addView(scrollView, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val brand = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        brand.addView(MoonCrescentView(this, ui), LinearLayout.LayoutParams(ui.dp(22), ui.dp(22)).apply {
            rightMargin = ui.dp(9)
        })
        brand.addView(moonText(ui, "MoonDrop", 21f, c.textPrimary, ui.medium).tracked(MoonTrack.TIGHT),
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        brand.addView(moonIconButton(ui, R.drawable.ic_moon_settings, MoonStrings.t("设置与更多")) { showSettingsSheet() })
        content.addView(brand)

        // One compact identity/status row; the connection sheet owns addresses and rename.
        localStatusRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(48)
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            setOnClickListener { showConnectionDetails() }
        }
        heroStatusDot = MoonStatusDot(this, ui).apply {
            setState(c.textSecondary)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        heroName = moonText(ui, "", 12f, c.textSecondary, maxLines = 1)
        heroStatusText = moonText(ui, MoonStrings.t("启动中"), 12f, c.textSecondary, maxLines = 1)
        localStatusRow.addView(heroStatusDot)
        val identityLabels = LinearLayout(this).apply {
            orientation = if (stackActions) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(heroName, if (stackActions) blockParams() else
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            if (!stackActions) addView(moonText(ui, " · ", 12f, c.textSecondary))
            addView(heroStatusText)
        }
        localStatusRow.addView(identityLabels, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        localStatusRow.addView(moonIcon(ui, R.drawable.ic_moon_chevron, 12, c.textSecondary),
            LinearLayout.LayoutParams(ui.dp(12), ui.dp(12)).apply { leftMargin = ui.dp(6) })
        content.addView(localStatusRow)

        content.addView(moonText(ui, MoonStrings.t("发送到附近"), 29f, c.textPrimary, ui.medium).apply {
            tracked(MoonTrack.TIGHT)
            isAccessibilityHeading = true
            setPadding(ui.dp(4), ui.dp(24), ui.dp(4), ui.dp(8))
        })
        peersCount = moonText(ui, "", 13f, c.textSecondary).apply {
            setPadding(ui.dp(4), 0, ui.dp(4), 0)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        content.addView(peersCount)

        // The idle field and real transfer/result occupy the same slot, never two cards.
        val field = FrameLayout(this)
        nearfield = MoonNearfieldView(this, ui)
        field.addView(nearfield, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        transferCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            minimumHeight = ui.dp(320)
            setPadding(ui.dp(20), ui.dp(24), ui.dp(20), ui.dp(20))
            visibility = View.GONE
        }
        val ringSize = maxOf(154, (112 * configuration.fontScale).toInt())
            .coerceAtMost((configuration.screenWidthDp - 60).coerceAtLeast(48))
        val ring = FrameLayout(this)
        transferProgress = MoonProgressView(this, ui)
        ring.addView(transferProgress, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        transferPercent = moonText(ui, "0%", 36f, c.primaryStrong, ui.regular, maxLines = 1).apply {
            gravity = Gravity.CENTER
            setPadding(ui.dp(12), ui.dp(12), ui.dp(12), ui.dp(12))
            setAutoSizeTextTypeUniformWithConfiguration(12, 36, 1, android.util.TypedValue.COMPLEX_UNIT_SP)
        }
        ring.addView(transferPercent, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        transferIcon = moonIcon(ui, R.drawable.ic_moon_send, 42, c.primary)
        ring.addView(transferIcon, FrameLayout.LayoutParams(ui.dp(42), ui.dp(42), Gravity.CENTER))
        transferCard.addView(ring, LinearLayout.LayoutParams(ui.dp(ringSize), ui.dp(ringSize)))
        transferTitle = moonText(ui, "", 16f, c.textPrimary, ui.medium).apply {
            gravity = Gravity.CENTER
            setPadding(0, ui.dp(18), 0, 0)
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        transferDetail = moonText(ui, "", 13f, c.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, ui.dp(8), 0, 0)
        }
        transferWarn = moonText(ui, MoonStrings.t("大文件传输中，请保持 MoonDrop 在前台"), 13f, c.warningText).apply {
            gravity = Gravity.CENTER
            setPadding(0, ui.dp(8), 0, 0)
            visibility = View.GONE
        }
        transferCard.addView(transferTitle, blockParams())
        transferCard.addView(transferDetail, blockParams())
        transferCard.addView(transferWarn, blockParams())
        field.addView(transferCard, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        content.addView(field, blockParams().apply {
            leftMargin = -ui.dp(12)
            rightMargin = -ui.dp(12)
        })

        val helpers = LinearLayout(this).apply {
            orientation = if (stackActions) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        rescanButton = MoonButton(
            this, ui, MoonButton.Style.GHOST, MoonStrings.t("重新扫描"), R.drawable.ic_moon_scan
        ).apply {
            textSize = 13f
            setTextColor(c.textSecondary)
            setOnClickListener { scanSubnet() }
        }
        helpers.addView(rescanButton)
        helpers.addView(MoonButton(this, ui, MoonButton.Style.GHOST, MoonStrings.t("手动连接"), R.drawable.ic_moon_plus).apply {
            textSize = 13f
            setTextColor(c.textSecondary)
            setOnClickListener { showManualDialog() }
        })
        content.addView(helpers)
        sendHint = moonText(ui, "", 12f, c.textSecondary).apply {
            gravity = Gravity.CENTER
            setPadding(0, ui.dp(4), 0, 0)
        }
        content.addView(sendHint)

        pendingCard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            minimumHeight = ui.dp(320)
            setPadding(ui.dp(20), ui.dp(24), ui.dp(20), ui.dp(24))
            visibility = View.GONE
        }
        pendingTitle = moonText(ui, "", 16f, c.textPrimary, ui.medium).apply {
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }
        pendingCard.addView(pendingTitle)
        val pendingActions = LinearLayout(this).apply {
            orientation = if (stackActions) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(8), 0, 0)
        }
        pendingSendButton = MoonButton(this, ui, MoonButton.Style.PRIMARY, MoonStrings.t("选择设备并发送")).apply {
            setOnClickListener { sendPending() }
        }
        pendingActions.addView(pendingSendButton, if (stackActions) blockParams() else
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        pendingActions.addView(MoonButton(this, ui, MoonButton.Style.GHOST, MoonStrings.t("取消")).apply {
            setOnClickListener {
                pendingUris.clear()
                autoPickerArmed = false
                updatePendingUi()
            }
        }, if (stackActions) blockParams(top = 8) else LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply { leftMargin = ui.dp(8) })
        pendingCard.addView(pendingActions)
        field.addView(pendingCard, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))

        // Bottom dock remains visible with real system insets; the field scrolls on short screens.
        val bottom = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(22), ui.dp(12), ui.dp(22), ui.dp(8))
        }
        val dock = LinearLayout(this).apply {
            orientation = if (stackActions) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            background = moonRounded(ui, c.surface, 24)
            setPadding(ui.dp(7), ui.dp(7), ui.dp(7), ui.dp(7))
        }
        sendFileButton = MoonActionButton(this, ui, MoonStrings.t("选择文件"), R.drawable.ic_moon_folder).apply {
            setOnClickListener { pickFiles() }
        }
        sendAlbumButton = MoonActionButton(this, ui, MoonStrings.t("相册"), R.drawable.ic_moon_album, primary = false).apply {
            setOnClickListener { pickFromAlbum() }
        }
        listOf(sendFileButton, sendAlbumButton).forEachIndexed { index, button ->
            dock.addView(button, if (stackActions) blockParams(top = if (index > 0) 6 else 0) else
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, if (index == 0) 1.45f else 1f).apply {
                    if (index > 0) leftMargin = ui.dp(6)
                })
        }
        bottom.addView(dock, blockParams())
        recentRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = ui.dp(64)
            setPadding(ui.dp(3), ui.dp(10), ui.dp(3), ui.dp(10))
            background = moonRippleBackground(ui, c.textSecondary)
            isClickable = true
            isFocusable = true
            setOnClickListener { showHistorySheet() }
        }
        recentRow.addView(moonIcon(ui, R.drawable.ic_moon_file, 22, c.textSecondary),
            LinearLayout.LayoutParams(ui.dp(22), ui.dp(22)).apply { rightMargin = ui.dp(12) })
        val recentLabels = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        recentLabels.addView(moonText(ui, MoonStrings.t("最近传输"), 13f, c.textPrimary))
        recentDetail = moonText(ui, MoonStrings.t("暂无传输记录 · 查看全部"), 12f, c.textSecondary, maxLines = 2).apply {
            ellipsize = TextUtils.TruncateAt.END
            setPadding(0, ui.dp(4), 0, 0)
        }
        recentLabels.addView(recentDetail)
        recentRow.addView(recentLabels, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        recentRow.addView(moonIcon(ui, R.drawable.ic_moon_chevron, 14, c.textSecondary))
        // Leave the anchored tray usable in landscape and at large system font sizes.
        (if (compactHeight) content else bottom).addView(recentRow, blockParams(top = 8))
        root.addView(bottom, blockParams())

        setContentView(root)
        applyEdgeToEdge()
        root.requestApplyInsets()
        refreshPeers()
        renderRecentTransfer()
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
            setPadding(ui.dp(4), ui.dp(8), ui.dp(4), ui.dp(8))
            addView(
                moonText(ui, title, MoonType.TITLE, ui.colors.textPrimary).apply {
                    setPadding(0, 0, ui.dp(12), 0)
                },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            )
            addView(trailing)
        }

    private fun appVersion(): String =
        packageManager.getPackageInfo(packageName, 0).versionName ?: ""

    /**
     * 设置入口：设置项、连接详情、帮助都收在这一层，主屏因此只留三件事——
     * 我是谁、发给谁、发过什么。
     */
    private fun showSettingsSheet() {
        val c = ui.colors
        val sheet = MoonSheet(this, ui, MoonStrings.t("设置"))

        // 外观：三档分段，选中态直接来自偏好，点击后整页重建以换主题与系统栏
        val appearances = listOf(
            MoonPrefs.APPEARANCE_SYSTEM,
            MoonPrefs.APPEARANCE_LIGHT,
            MoonPrefs.APPEARANCE_DARK
        )
        val appearanceChoice = MoonSegmented(
            this,
            ui,
            listOf(MoonStrings.t("跟随系统"), MoonStrings.t("浅色"), MoonStrings.t("深色")),
            initial = appearances.indexOf(MoonPrefs.appearance).coerceAtLeast(0)
        ) { index ->
            val value = appearances[index]
            if (value != MoonPrefs.appearance) {
                MoonPrefs.setAppearance(value)
                sheet.dismiss()
                recreate()
            }
        }
        applySegmentDescriptions(appearanceChoice, listOf(
            MoonStrings.t("外观：跟随系统"),
            MoonStrings.t("外观：浅色"),
            MoonStrings.t("外观：深色")
        ))
        sheet.add(choiceRow(MoonStrings.t("外观"), appearanceChoice))
        sheet.add(moonDivider(ui, 0))

        // 语言：只切文案，不改布局结构
        val languages = listOf(MoonPrefs.LANGUAGE_ZH, MoonPrefs.LANGUAGE_EN)
        val languageChoice = MoonSegmented(
            this,
            ui,
            listOf("简体中文", "English"),
            initial = languages.indexOf(MoonPrefs.language).coerceAtLeast(0)
        ) { index ->
            val value = languages[index]
            if (value != MoonPrefs.language) {
                MoonPrefs.setLanguage(value)
                MoonStrings.language = value
                sheet.dismiss()
                recreate()
            }
        }
        applySegmentDescriptions(languageChoice, listOf(
            MoonStrings.t("语言：简体中文"),
            MoonStrings.t("语言：English")
        ))
        sheet.add(choiceRow(MoonStrings.t("语言"), languageChoice))
        sheet.add(moonDivider(ui, 44))

        autoSaveSwitch = MoonSwitch(this, ui).apply {
            setCheckedSilently(GallerySettings.isEnabled(this@MainActivity))
            contentDescription = MoonStrings.t("收到的照片自动存入相册")
            onCheckedChange = { GallerySettings.setEnabled(this@MainActivity, it) }
        }
        sheet.add(settingRow(MoonStrings.t("收到的照片自动存入相册"), autoSaveSwitch))
        sheet.add(moonDivider(ui, 44))

        batteryValue = moonText(ui, MoonStrings.t("去设置"), MoonType.META, c.primaryStrong)
        batteryRow = settingRow(MoonStrings.t("后台接收"), LinearLayout(this).apply {
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
        sheet.add(batteryRow)
        sheet.add(moonDivider(ui, 44))

        sheet.addAction(R.drawable.ic_moon_link, MoonStrings.t("连接详情")) {
            sheet.dismiss()
            showConnectionDetails()
        }
        sheet.addAction(R.drawable.ic_moon_info, MoonStrings.t("存储位置与常见问题")) {
            sheet.dismiss()
            showHelp()
        }
        sheet.show()
        updateBatteryHint()
    }

    /** 设置里的选项行：标题在上，整宽控件在下，沿用弹层现有的字号与留白 */
    private fun choiceRow(title: String, control: View): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(4), ui.dp(12), ui.dp(4), ui.dp(6))
            addView(
                moonText(ui, title, MoonType.TITLE, ui.colors.textPrimary).apply {
                    isAccessibilityHeading = true
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
                )
            )
            addView(control, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { topMargin = ui.dp(10) })
        }

    /** 分段控制的每一项都是纯文字，补一句语境供读屏使用 */
    private fun applySegmentDescriptions(segmented: MoonSegmented, descriptions: List<String>) {
        descriptions.forEachIndexed { index, description ->
            segmented.getChildAt(index)?.contentDescription = description
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
        val color = when {
            port <= 0 -> c.textTertiary
            addresses.isEmpty() -> c.warning
            ReceiverRuntime.advertising -> c.success
            else -> c.warning
        }
        heroStatusDot.setState(color)
        heroStatusText.text = when {
            port <= 0 -> MoonStrings.t("启动中")
            addresses.isEmpty() -> MoonStrings.t("未连接")
            ReceiverRuntime.advertising -> MoonStrings.t("可接收")
            else -> MoonStrings.t("广播未上线")
        }
        heroStatusText.setTextColor(c.textSecondary)
        localStatusRow.contentDescription = MoonStrings.f(
            "%s，%s，查看连接详情或重命名", heroName.text, heroStatusText.text
        )
    }

    // MARK: - 状态刷新

    private fun refreshRuntime() {
        if (!::heroName.isInitialized) return
        val port = ReceiverRuntime.port
        val addresses = SubnetScan.localIPv4s()
        heroName.text = DeviceIdentity.name(this)
        renderStatusChrome(port, addresses)
        if (port > 0 && screenVisible) startDiscovery(port)

        if (ReceiverRuntime.lastResult.isNotEmpty() &&
            ReceiverRuntime.lastResult != lastReceiveResult
        ) {
            lastReceiveResult = ReceiverRuntime.lastResult
            // Match the service's completion prefix, never words inside a filename.
            // 结果可能是在切换语言之前生成的，两种语言的前缀都要认。
            val error = !hasReceivedPrefix(lastReceiveResult)
            showResult(
                lastReceiveResult,
                error,
                if (error) MoonStrings.t("接收失败") else MoonStrings.t("接收完成")
            )
            refreshReceived()
        }
        refreshTransferUi()
    }

    private fun hasReceivedPrefix(message: String): Boolean = listOf(
        "已接收：", "已接收并存入相册：",
        "Received: ", "Received and saved to Photos: "
    ).any { message.startsWith(it) }

    /// 连接详情弹层用：把「没地址」和「广播没上线」分开说清楚
    private fun networkSummary(port: Int): String {
        if (port <= 0) return MoonStrings.t("接收服务还在启动，请稍等")
        val addresses = SubnetScan.localIPv4s()
        val addressPart = if (addresses.isEmpty()) {
            MoonStrings.t("未取得局域网地址，请确认已连接 Wi-Fi")
        } else {
            addresses.joinToString(", ")
        }
        val advertisePart = when {
            ReceiverRuntime.advertising -> MoonStrings.t("广播已上线")
            ReceiverRuntime.advertiseError.isNotEmpty() -> ReceiverRuntime.advertiseError
            else -> MoonStrings.t("广播未确认，可改用扫描或手动填写 IP")
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
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
            ))
        }

    private fun showRenameDialog() {
        val sheet = MoonSheet(this, ui, MoonStrings.t("重命名本机"))
        val input = sheetInput(MoonStrings.t("例如 客厅的安卓机"), DeviceIdentity.name(this)).apply {
            filters = arrayOf(
                android.text.InputFilter.LengthFilter(DeviceIdentity.MAX_NAME_LENGTH)
            )
        }
        sheet.add(input)
        sheet.add(moonText(
            ui,
            MoonStrings.f(
                "其他设备的 MoonDrop 列表里显示这个名字，最长 %d 个字符。",
                DeviceIdentity.MAX_NAME_LENGTH
            ),
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, ui.dp(8), 0, 0) })
        sheet.add(sheetPrimaryButton(MoonStrings.t("保存")) {
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
        toast(MoonStrings.f("已改名为「%s」", saved))
    }

    /**
     * Bonjour 之外的兜底：组播被屏蔽的网络里靠这个把设备找回来。
     *
     * 扫描是流式的：探测到一台就立刻加进设备列表，界面因此能边扫边显示，
     * 而不是盯着一个空转的圈等最长 12 秒。
     */
    private fun scanSubnet() {
        if (scanning) return
        scanning = true
        scanFound = 0
        scanStartedAt = SystemClock.uptimeMillis()
        updateScanButton()
        nearfield.setScanning(true)
        updatePeerCaption()
        SubnetScan.run(
            onProgress = { progress ->
                if (isFinishing || isDestroyed) return@run
                scanFound = progress.found.size
                // 命中一台就立刻放进列表，设备可以边扫边冒出来
                addScannedPeers(progress.found)
                refreshPeers()
                updatePeerCaption()
            },
            completion = { final ->
                if (isFinishing || isDestroyed) return@run
                addScannedPeers(final.found)
                refreshPeers()
                // 快网络下扫描转瞬即逝，至少让雷达转起来一小会儿，否则等于没反馈
                val elapsed = SystemClock.uptimeMillis() - scanStartedAt
                val delay = maxOf(0L, MINIMUM_SCAN_MS - elapsed)
                handler.postDelayed({
                    scanning = false
                    updateScanButton()
                    nearfield.setScanning(false)
                    updatePeerCaption()
                    toast(if (final.found.isEmpty()) {
                        MoonStrings.t("没有扫到设备，网络可能开了客户端隔离")
                    } else {
                        MoonStrings.f("扫描到 %d 台设备", final.found.size)
                    })
                }, delay)
            }
        )
    }

    /** 扫描命中的设备放进列表；同一台只留一条 */
    private fun addScannedPeers(hits: List<SubnetScan.Found>) {
        for (hit in hits) {
            val peer = Peer(name = hit.name, host = hit.host, port = hit.port, manual = true)
            scannedPeers.removeAll { it.endpoint == peer.endpoint }
            scannedPeers.add(peer)
        }
    }

    /** 扫描中把按钮换成雷达表盘，结束后换回普通图标 */
    private fun updateScanButton() {
        if (!::rescanButton.isInitialized) return
        if (scanning) {
            val radar = radarDrawable ?: MoonRadarDrawable(ui).also { radarDrawable = it }
            radar.setBounds(0, 0, ui.dp(20), ui.dp(20))
            rescanButton.text = MoonStrings.t("正在扫描")
            rescanButton.setCompoundDrawables(radar, null, null, null)
            rescanButton.isEnabled = false
            // 禁用态默认会把整块压到 40%，雷达会看不清；这里保持满亮
            rescanButton.alpha = 1f
            radar.start()
        } else {
            rescanButton.text = MoonStrings.t("重新扫描")
            rescanButton.isEnabled = true
            // setEnabled(true) 会重跑 applyStyle，把文字色改回 primaryStrong；这里改回中性色
            rescanButton.setTextColor(ui.colors.textSecondary)
            val drawable = resources.getDrawable(R.drawable.ic_moon_scan, theme).mutate()
            drawable.setTint(ui.colors.primaryStrong)
            drawable.setBounds(0, 0, ui.dp(20), ui.dp(20))
            rescanButton.setCompoundDrawables(drawable, null, null, null)
            radarDrawable?.stop()
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
        nearfield.visibility = if (transferCard.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        refreshSendState()
    }

    private fun bindActiveTransfer(outgoing: Boolean) {
        val c = ui.colors
        transferCard.visibility = View.VISIBLE
        transferIcon.visibility = View.GONE
        transferTitle.text = if (outgoing) MoonStrings.t("正在发送") else MoonStrings.t("正在接收")
        transferTitle.setTextColor(c.textPrimary)
        val reportedProgress = if (outgoing) sendingProgress else ReceiverRuntime.progress
        val progress = if (reportedProgress.isFinite()) reportedProgress.coerceIn(0.0, 1.0) else 0.0
        transferPercent.visibility = View.VISIBLE
        transferPercent.text = "${(progress * 100).toInt()}%"
        transferPercent.contentDescription = MoonStrings.f(
            "%s，已完成 %d%%", transferTitle.text, (progress * 100).toInt()
        )
        transferPercent.setTextColor(c.primaryStrong)
        transferProgress.setProgress(progress.toFloat())
        transferDetail.text = if (outgoing) {
            sendingName.ifEmpty { MoonStrings.t("准备发送…") }
        } else {
            ReceiverRuntime.statusText.ifEmpty { MoonStrings.t("接收中…") }
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
        transferIcon.visibility = View.VISIBLE
        transferIcon.setColorFilter(if (displayResultIsError) c.dangerText else c.success)
        transferTitle.text = displayResultTitle
        transferTitle.setTextColor(
            if (displayResultIsError) c.dangerText else c.successText
        )
        transferPercent.visibility = View.GONE
        transferProgress.setProgress(if (displayResultIsError) 0f else 1f,
            if (displayResultIsError) c.dangerText else c.success)
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
        if (!::nearfield.isInitialized) return
        val peers = mergedPeers()
        nearfield.setDevices(peers.map { peer ->
            MoonNearbyDevice(peer.endpoint, peer.name, peerConnection(peer)) { showSendOptions(peer) }
        })
        updatePeerCaption()
        refreshSendState()
    }

    private fun updatePeerCaption() {
        if (!::peersCount.isInitialized) return
        val count = mergedPeers().size
        peersCount.text = when {
            // 扫描中的副标题：说清楚正在做什么、这次扫描找到了几台
            scanning -> if (scanFound > 0) {
                MoonStrings.f("正在扫描 · 本次找到 %d 台设备", scanFound)
            } else {
                MoonStrings.t("正在扫描 · 正在逐个探测局域网地址")
            }
            count == 0 -> MoonStrings.t("0 台设备 · 发现后即可发送")
            else -> MoonStrings.f("%d 台设备，轻点即可发送", count)
        }
    }

    private fun peerConnection(peer: Peer): String = when {
        peer.peerToPeer -> MoonStrings.t("点对点")
        // Subnet-scan hits use the protocol's manual flag, but are still LAN discoveries.
        scannedPeers.any { it.endpoint == peer.endpoint } -> MoonStrings.t("局域网")
        peer.manual -> MoonStrings.t("手动")
        else -> MoonStrings.t("局域网")
    }

    private fun deviceRow(peer: Peer, onClick: () -> Unit): LinearLayout {
        val c = ui.colors
        val row = moonListRow(
            ui,
            R.drawable.ic_moon_device,
            peer.name,
            subtitle = peerSubtitle(peer),
            trailing = moonIcon(ui, R.drawable.ic_moon_chevron, 16, c.textTertiary),
            iconTint = c.textSecondary,
            onClick = onClick
        )
        row.contentDescription = MoonStrings.f(
            "%s，%s:%d，点按发送文件", peer.name, peer.host, peer.port
        )
        return row
    }

    private fun peerSubtitle(peer: Peer): String {
        val route = when {
            peer.peerToPeer -> MoonStrings.t("点对点直连")
            peer.manual -> MoonStrings.t("手动添加")
            else -> null
        }
        val address = "${peer.host}:${peer.port}"
        return if (route == null) address else "$route · $address"
    }

    private fun refreshSendState() {
        if (!::sendFileButton.isInitialized) return
        val peers = mergedPeers()
        sendHint.text = when {
            sending -> MoonStrings.t("正在发送，完成后可选择新文件")
            peers.isEmpty() -> MoonStrings.t("连接设备后可选择文件或相册")
            else -> ""
        }
        sendHint.visibility = if (sendHint.text.isEmpty()) View.GONE else View.VISIBLE
        val enabled = peers.isNotEmpty() && !sending
        sendFileButton.applyLook(enabled)
        sendAlbumButton.applyLook(enabled)
        sendFileButton.contentDescription = if (enabled) {
            MoonStrings.t("选择文件")
        } else {
            MoonStrings.f("选择文件，%s", sendHint.text)
        }
        sendAlbumButton.contentDescription = if (enabled) {
            MoonStrings.t("相册")
        } else {
            MoonStrings.f("相册，%s", sendHint.text)
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
        batteryValue.text = if (ignoring) MoonStrings.t("已允许") else MoonStrings.t("去设置")
        batteryValue.setTextColor(
            if (ignoring) ui.colors.textSecondary else ui.colors.primaryStrong
        )
        batteryRow.contentDescription = if (ignoring) {
            MoonStrings.t("后台接收，电池优化已关闭")
        } else {
            MoonStrings.t("后台接收，点按关闭电池优化")
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean =
        getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(packageName) == true

    private fun requestIgnoreBatteryOptimizations() {
        if (isIgnoringBatteryOptimizations()) {
            toast(MoonStrings.t("已允许后台接收"))
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
            toast(MoonStrings.t("请在系统设置中关闭 MoonDrop 的电池优化"))
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
        val showPending = pendingUris.isNotEmpty() && !sending &&
            !ReceiverRuntime.receiving && displayResult.isEmpty()
        pendingCard.visibility = if (showPending) View.VISIBLE else View.GONE
        nearfield.visibility = if (showPending || transferCard.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        pendingTitle.text = MoonStrings.f("待发送 · %d 个文件", pendingUris.size)
        pendingSendButton.isEnabled = mergedPeers().isNotEmpty() && !sending
    }

    private fun sendPending() {
        if (pendingUris.isEmpty() || sending) return
        prepareAndSend(pendingUris.toList(), fromPending = true)
    }

    private fun showSendOptions(peer: Peer) {
        if (sending) {
            toast(MoonStrings.t("正在传输，请稍候"))
            return
        }
        val sheet = MoonSheet(this, ui, MoonStrings.f("发送到 %s", peer.name))
        sheet.add(infoRow(MoonStrings.t("设备"), peer.name))
        sheet.add(moonText(
            ui,
            "${peer.host}:${peer.port}" + if (peer.peerToPeer) " · " + MoonStrings.t("点对点直连") else "",
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, 0, 0, ui.dp(4)) })
        sheet.addAction(R.drawable.ic_moon_file, MoonStrings.t("选择文件")) {
            targetPeer = peer
            sheet.dismiss()
            pickFiles()
        }
        sheet.addAction(R.drawable.ic_moon_album, MoonStrings.t("从相册发送")) {
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
        val sheet = MoonSheet(this, ui, MoonStrings.t("连接详情"))
        sheet.add(infoRow(MoonStrings.t("本机名称"), DeviceIdentity.name(this)))
        sheet.addAction(R.drawable.ic_moon_edit, MoonStrings.t("重命名本机")) {
            sheet.dismiss()
            showRenameDialog()
        }
        sheet.add(infoRow(MoonStrings.t("监听端口"), if (port > 0) port.toString() else MoonStrings.t("启动中")))
        sheet.add(infoRow(
            MoonStrings.t("局域网地址"),
            addresses.joinToString(", ").ifEmpty { MoonStrings.t("未连接 Wi-Fi") }
        ))
        sheet.add(infoRow(
            MoonStrings.t("广播状态"),
            when {
                ReceiverRuntime.advertising -> MoonStrings.t("已上线")
                ReceiverRuntime.advertiseError.isNotEmpty() -> MoonStrings.t("失败")
                else -> MoonStrings.t("未确认")
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
        sheet.add(sheetPrimaryButton(MoonStrings.t("复制地址")) {
            val address = addresses.firstOrNull()
            if (address == null) {
                toast(MoonStrings.t("还没有局域网地址"))
            } else {
                copyText("$address:${if (port > 0) port else 52345}")
                toast(MoonStrings.t("已复制地址"))
            }
        })
        sheet.show()
    }

    private fun infoRow(label: String, value: String): LinearLayout =
        LinearLayout(this).apply {
            val stacked = resources.configuration.fontScale >= 1.4f ||
                resources.configuration.screenWidthDp < 340
            orientation = if (stacked) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(8), 0, ui.dp(8))
            addView(moonText(ui, label, 13f, ui.colors.textSecondary))
            addView(moonText(ui, value, 13f, ui.colors.textPrimary, ui.medium).apply {
                gravity = if (stacked) Gravity.START else Gravity.END
                setPadding(if (stacked) 0 else ui.dp(12), if (stacked) ui.dp(4) else 0, 0, 0)
            }, if (stacked) blockParams() else
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
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
        val sheet = MoonSheet(this, ui, MoonStrings.t("存储位置与常见问题"))
        sheet.add(helpHeading(MoonStrings.t("收到的文件放在哪")))
        sheet.add(helpBody(MoonStrings.t(
            "普通文件保存在「下载 / 来自另一台Mac」。\n\n" +
                "开关开启时，图片和视频直接写入「Pictures / MoonDrop」或「Movies / MoonDrop」，" +
                "只保存一份，相册里不会出现重复。关闭开关后媒体留在下载目录，" +
                "可以在记录里点「⋯ → 存入相册」。"
        )))
        sheet.add(helpHeading(MoonStrings.t("看不见设备怎么办")))
        sheet.add(helpBody(MoonStrings.t(
            "确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。Android 设备必须同一 Wi-Fi；" +
                "附近的 Apple 设备即使连着别的网络，也会以「点对点」出现。\n\n" +
                "仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。"
        )))
        sheet.add(helpHeading(MoonStrings.t("后台接收")))
        sheet.add(helpBody(MoonStrings.t(
            "接收服务在前台通知里运行，切到后台也能继续接收。关闭电池优化可以减少锁屏后被系统冻结的情况。"
        )))
        sheet.add(helpHeading(MoonStrings.t("关于")))
        sheet.add(helpBody(MoonStrings.f(
            "MoonDrop %s · 局域网直连，不经过云端。", version.ifEmpty { "1.6.0" }
        )))
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
        val sheet = MoonSheet(this, ui, MoonStrings.t("手动添加设备"))
        val hostInput = sheetInput(MoonStrings.t("IP 地址，例如 192.168.1.20"))
        val portInput = sheetInput(MoonStrings.t("端口"), "52345").apply {
            inputType = InputType.TYPE_CLASS_NUMBER
        }
        val nameInput = sheetInput(MoonStrings.t("备注名（可选）"))
        sheet.add(hostInput)
        sheet.add(portInput)
        sheet.add(nameInput)
        sheet.add(moonText(
            ui,
            MoonStrings.t("对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。"),
            12f,
            ui.colors.textSecondary
        ).apply { setPadding(0, ui.dp(10), 0, 0) })
        sheet.add(sheetPrimaryButton(MoonStrings.t("连接")) {
            val host = hostInput.text.toString().trim()
            val port = portInput.text.toString().toIntOrNull() ?: 52345
            val name = nameInput.text.toString().trim()
            if (host.isEmpty()) {
                toast(MoonStrings.t("请填写 IP 地址"))
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
                    toast(MoonStrings.f("已添加 %s", peer.name))
                }
            } catch (_: Exception) {
                runOnUiThread {
                    toast(MoonStrings.f("连不上 %s:%d，确认对端在运行且在同一局域网", host, port))
                }
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
                        toast(MoonStrings.t("没有可发送的文件"))
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
                runOnUiThread { toast(MoonStrings.f("读取失败：%s", error.message)) }
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
            toast(MoonStrings.t("没有可用设备"))
            return
        }
        if (peers.size != lastCount && attempt < 6) {
            handler.postDelayed({
                presentDeviceChooser(files, fromPending, restoreUris, attempt + 1, peers.size)
            }, 500)
            return
        }

        val sheet = MoonSheet(this, ui, MoonStrings.t("发送到哪台设备？"))
        var picked = false
        peers.forEachIndexed { index, peer ->
            if (index > 0) sheet.add(moonDivider(ui, 56))
            sheet.add(deviceRow(peer) {
                // A second chooser must not consume shared files while another send is active.
                if (sending) {
                    toast(MoonStrings.t("正在传输，请稍候"))
                    return@deviceRow
                }
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
            addView(MoonButton(this@MainActivity, ui, MoonButton.Style.GHOST, MoonStrings.t("取消")).apply {
                setOnClickListener { sheet.dismiss() }
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT
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
                                MoonStrings.f("已发送 %d 个文件到 %s", files.size, peer.name),
                                error = false,
                                title = MoonStrings.t("发送完成")
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
                                MoonStrings.f("发送失败：%s", it.message),
                                error = true,
                                title = MoonStrings.t("发送失败")
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

    private fun showHistorySheet() {
        if (historySheet?.isShowing == true || isFinishing || isDestroyed) return
        val sheet = MoonSheet(this, ui, MoonStrings.t("传输记录"))
        val clear = moonText(ui, MoonStrings.t("清空"), 13f, ui.colors.dangerText, ui.medium).apply {
            minHeight = ui.dp(48)
            minWidth = ui.dp(48)
            gravity = Gravity.CENTER
            setPadding(ui.dp(12), ui.dp(8), ui.dp(12), ui.dp(8))
            background = moonRippleBackground(ui, ui.colors.dangerText)
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (showReceivedHistory) confirmClearReceived() else confirmClearSent()
            }
        }
        val toolbar = LinearLayout(this).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            addView(clear)
        }
        val segmented = MoonSegmented(this, ui, listOf(MoonStrings.t("已发送"), MoonStrings.t("已接收")),
            initial = if (showReceivedHistory) 1 else 0) { index ->
            showReceivedHistory = index == 1
            renderHistory()
        }
        val host = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val container = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        sheet.add(segmented)
        sheet.add(toolbar)
        sheet.add(host)
        // No home-owned or detached history views are retained between presentations.
        sheet.setOnShowListener {
            historySheet = sheet
            historyClear = clear
            historySegmented = segmented
            historyHost = host
            historyContainer = container
            updateHistoryLabels()
            renderHistory()
            refreshReceived()
        }
        sheet.setOnDismissListener {
            if (historySheet === sheet) {
                historySheet = null
                historyClear = null
                historySegmented = null
                historyHost = null
                historyContainer = null
            }
        }
        sheet.show()
    }

    private fun renderRecentTransfer() {
        if (!::recentDetail.isInitialized) return
        val sent = sentRecords.maxByOrNull { it.date }
        val received = receivedItems.maxByOrNull { it.modified }
        val metadata = when {
            received != null && (sent == null || received.modified >= sent.date) -> {
                MoonStrings.f(
                    "%s · 已接收 · %s · %s",
                    received.name, NetUtil.formatBytes(received.size), historyTime(received.modified)
                )
            }
            sent != null -> {
                val name = if (sent.names.size == 1) sent.names[0]
                    else MoonStrings.f("%d 个文件", sent.names.size)
                MoonStrings.f(
                    "%s · 已发送至 %s · %s · %s",
                    name, sent.target, NetUtil.formatBytes(sent.size), historyTime(sent.date)
                )
            }
            else -> MoonStrings.t("暂无传输记录 · 查看全部")
        }
        recentDetail.text = metadata
        recentRow.contentDescription = MoonStrings.f("最近传输，%s，打开全部传输记录", metadata)
    }

    private fun historyTime(timestamp: Long): String = dayLabel(timestamp) + " " +
        SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(timestamp))

    private fun refreshSent() {
        sentRecords.clear()
        sentRecords.addAll(SentStore.load(this))
        renderRecentTransfer()
        if (historySheet?.isShowing == true) {
            updateHistoryLabels()
            if (!showReceivedHistory) renderHistory()
        }
    }

    private fun refreshReceived() {
        val token = ++receivedRefreshToken
        thread(name = "macdrop-received") {
            val items = try {
                store.listReceived()
            } catch (_: Exception) {
                emptyList()
            }
            runOnUiThread {
                if (isFinishing || isDestroyed || token != receivedRefreshToken) return@runOnUiThread
                receivedItems.clear()
                receivedItems.addAll(items)
                renderRecentTransfer()
                if (historySheet?.isShowing == true) {
                    updateHistoryLabels()
                    if (showReceivedHistory) renderHistory()
                }
            }
        }
    }

    private fun updateHistoryLabels() {
        if (historySheet?.isShowing != true) return
        val segmented = historySegmented ?: return
        segmented.setLabel(0, if (sentRecords.isEmpty()) MoonStrings.t("已发送")
            else MoonStrings.f("已发送 %d", sentRecords.size))
        segmented.setLabel(1, if (receivedItems.isEmpty()) MoonStrings.t("已接收")
            else MoonStrings.f("已接收 %d", receivedItems.size))
    }

    private fun renderHistory() {
        if (historySheet?.isShowing != true) return
        val container = historyContainer ?: return
        val host = historyHost ?: return
        val clear = historyClear ?: return
        val hasItems = if (showReceivedHistory) receivedItems.isNotEmpty() else sentRecords.isNotEmpty()
        clear.visibility = if (hasItems) View.VISIBLE else View.GONE
        clear.text = if (showReceivedHistory) MoonStrings.t("删除全部") else MoonStrings.t("清空记录")
        clear.setTextColor(if (showReceivedHistory) ui.colors.dangerText else ui.colors.textSecondary)
        host.removeAllViews()
        container.removeAllViews()
        if (!hasItems) {
            if (showReceivedHistory) {
                host.addView(moonEmptyState(ui, R.drawable.ic_moon_folder,
                    MoonStrings.t("还没有接收文件"),
                    MoonStrings.t("其他设备发来的文件会出现在这里"),
                    MoonStrings.t("刷新")) { refreshReceived() })
            } else {
                host.addView(moonEmptyState(ui, R.drawable.ic_moon_send,
                    MoonStrings.t("还没有发送记录"),
                    MoonStrings.t("发出的文件会按时间出现在这里")))
            }
            return
        }
        host.addView(container)
        if (showReceivedHistory) renderReceivedItems(container) else renderSentItems(container)
    }

    private fun renderSentItems(container: LinearLayout) {
        var currentDay = ""
        sentRecords.forEachIndexed { index, record ->
            val day = dayLabel(record.date)
            if (day != currentDay) {
                currentDay = day
                container.addView(groupHeader(day))
            } else if (index > 0) {
                container.addView(moonDivider(ui, 38))
            }
            container.addView(sentRow(record))
        }
    }

    private fun sentRow(record: SentRecord): LinearLayout {
        val c = ui.colors
        val name = if (record.names.size == 1) record.names[0]
            else MoonStrings.f("%d 个文件", record.names.size)
        val row = moonListRow(
            ui,
            fileIcon(name),
            name,
            subtitle = "→ ${record.target} · ${NetUtil.formatBytes(record.size)} · " +
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(record.date)),
            trailing = moonIcon(ui, R.drawable.ic_moon_check, 16, c.success)
        )
        return row
    }

    private fun renderReceivedItems(container: LinearLayout) {
        val swipeRows = mutableListOf<SwipeRowLayout>()
        var currentDay = ""
        receivedItems.forEachIndexed { index, entry ->
            val day = dayLabel(entry.modified)
            if (day != currentDay) {
                currentDay = day
                container.addView(groupHeader(day))
            } else if (index > 0) {
                container.addView(moonDivider(ui, 38))
            }
            val row = receivedRow(entry)
            val swipeRow = SwipeRowLayout(this).apply {
                setForeground(row)
                onDelete = { confirmDeleteEntry(entry) }
                onOpen = { swipeRows.forEach { other -> if (other !== this) other.close() } }
            }
            swipeRows.add(swipeRow)
            container.addView(swipeRow)
        }
    }

    private fun receivedRow(entry: ReceivedEntry): LinearLayout {
        val row = moonListRow(
            ui,
            fileIcon(entry.name),
            entry.name,
            subtitle = "${NetUtil.formatBytes(entry.size)} · " +
                SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(entry.modified)),
            trailing = moonIconButton(ui, R.drawable.ic_moon_more, MoonStrings.t("更多操作")) {
                showEntryActions(entry)
            },
            onClick = { openEntry(entry) }
        )
        row.background = moonRipple(
            ui, moonRounded(ui, ui.colors.surface, 0), ui.alpha(ui.colors.textSecondary, 0.12f)
        )
        return row
    }

    private fun groupHeader(label: String): TextView =
        moonText(ui, label, MoonType.META, ui.colors.textSecondary, ui.medium).apply {
            tracked(MoonTrack.WIDE)
            setPadding(0, ui.dp(20), 0, ui.dp(8))
        }

    private fun dayLabel(timestamp: Long): String {
        val today = Calendar.getInstance()
        val target = Calendar.getInstance().apply { timeInMillis = timestamp }
        if (today.get(Calendar.YEAR) == target.get(Calendar.YEAR) &&
            today.get(Calendar.DAY_OF_YEAR) == target.get(Calendar.DAY_OF_YEAR)
        ) {
            return MoonStrings.t("今天")
        }
        val yesterday = (today.clone() as Calendar).apply {
            add(Calendar.DAY_OF_YEAR, -1)
        }
        if (yesterday.get(Calendar.YEAR) == target.get(Calendar.YEAR) &&
            yesterday.get(Calendar.DAY_OF_YEAR) == target.get(Calendar.DAY_OF_YEAR)
        ) {
            return MoonStrings.t("昨天")
        }
        val sameYear = today.get(Calendar.YEAR) == target.get(Calendar.YEAR)
        val pattern = if (MoonStrings.isEnglish) {
            if (sameYear) "MMM d" else "MMM d, yyyy"
        } else {
            if (sameYear) "M月d日" else "yyyy年M月d日"
        }
        return SimpleDateFormat(pattern, MoonStrings.locale()).format(Date(timestamp))
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
        sheet.add(infoRow(MoonStrings.t("文件"), entry.name))
        sheet.addAction(
            if (isApk(entry)) R.drawable.ic_moon_apk else R.drawable.ic_moon_file,
            if (isApk(entry)) MoonStrings.t("安装") else MoonStrings.t("打开")
        ) {
            sheet.dismiss()
            openEntry(entry)
        }
        sheet.addAction(R.drawable.ic_moon_share, MoonStrings.t("分享")) {
            sheet.dismiss()
            shareEntry(entry)
        }
        if (GallerySettings.isMedia(entry.name) &&
            !GallerySettings.isInGallery(entry.relativePath)
        ) {
            sheet.addAction(R.drawable.ic_moon_download, MoonStrings.t("存入相册")) {
                sheet.dismiss()
                saveToGallery(entry)
            }
        }
        sheet.addAction(R.drawable.ic_moon_delete, MoonStrings.t("删除"), danger = true) {
            sheet.dismiss()
            confirmDeleteEntry(entry)
        }
        sheet.show()
    }

    private fun confirmClearSent() {
        if (sentRecords.isEmpty()) return
        AlertDialog.Builder(this)
            .setTitle(MoonStrings.t("清空发送记录？"))
            .setMessage(MoonStrings.t("只清列表，已经发出去的文件不受影响。"))
            .setPositiveButton(MoonStrings.t("清空")) { _, _ ->
                SentStore.clear(this)
                refreshSent()
            }
            .setNegativeButton(MoonStrings.t("取消"), null)
            .show()
    }

    private fun confirmClearReceived() {
        AlertDialog.Builder(this)
            .setTitle(MoonStrings.t("清空已接收？"))
            .setMessage(MoonStrings.t("「下载 / 来自另一台Mac」里的文件会被删除，无法恢复。已经存入系统相册的图片和视频会保留在相册里，只是从这个列表移除。"))
            .setPositiveButton(MoonStrings.t("删除全部")) { _, _ ->
                thread(name = "macdrop-clear") {
                    runCatching { store.clearReceived() }
                    runOnUiThread { refreshReceived() }
                }
            }
            .setNegativeButton(MoonStrings.t("取消"), null)
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
            toast(MoonStrings.t("没有可打开此文件的应用"))
            shareEntry(entry)
        } catch (_: Exception) {
            toast(MoonStrings.t("文件不可用，可能已被移动或删除"))
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
                .setTitle(MoonStrings.t("需要安装权限"))
                .setMessage(MoonStrings.t("系统默认禁止应用安装 APK。请在设置中允许 MoonDrop「安装未知应用」，返回后会自动继续安装。"))
                .setPositiveButton(MoonStrings.t("去设置")) { _, _ -> openInstallPermissionSettings() }
                .setNegativeButton(MoonStrings.t("取消")) { _, _ -> pendingInstall = null }
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
            toast(MoonStrings.t("安装包不可用，可能已被移动或删除"))
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
            toast(MoonStrings.t("没有可用的安装程序"))
            return
        }
        view.setClassName(target.activityInfo.packageName, target.activityInfo.name)
        try {
            startActivity(view)
        } catch (_: Exception) {
            toast(MoonStrings.t("没有可用的安装程序"))
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
            toast(MoonStrings.t("请手动在系统设置中允许安装未知应用"))
        }
    }

    private fun shareEntry(entry: ReceivedEntry) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = contentResolver.getType(entry.uri) ?: "*/*"
            putExtra(Intent.EXTRA_STREAM, entry.uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(intent, MoonStrings.t("分享文件")))
    }

    private fun confirmDeleteEntry(entry: ReceivedEntry) {
        AlertDialog.Builder(this)
            .setTitle(MoonStrings.t("删除文件？"))
            .setMessage(
                MoonStrings.f("将删除「%s」的实际文件，无法恢复。", entry.name) +
                    if (GallerySettings.isInGallery(entry.relativePath)) {
                        MoonStrings.t("它也会从系统相册中删除。")
                    } else {
                        ""
                    }
            )
            .setPositiveButton(MoonStrings.t("删除")) { _, _ -> deleteEntry(entry) }
            .setNegativeButton(MoonStrings.t("取消"), null)
            .show()
            .getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(ui.colors.dangerText)
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
                    onSuccess = { MoonStrings.f("已存入相册：%s", entry.name) },
                    onFailure = {
                        MoonStrings.f(
                            "存入相册失败：%s", it.message ?: MoonStrings.t("未知错误")
                        )
                    }
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

        /// 雷达动画的最短展示时长：快网络下扫描转瞬即逝，一闪而过等于没反馈
        private const val MINIMUM_SCAN_MS = 1000L
    }
}
