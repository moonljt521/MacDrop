package com.macdrop.mobile.ui

import java.util.Locale

/**
 * 运行时文案表：键是界面上原本写死的中文，值是对应的英文。
 *
 * 不抽 strings.xml 是有意的——整个界面都是代码构建的原生 View，
 * 这张表让「改语言」只是换一次查表结果，不需要给每个 View 找资源 id。
 */
object MoonStrings {

    var language: String = "zh"

    val isEnglish: Boolean get() = language == "en"

    fun t(zh: String): String = if (isEnglish) ENGLISH[zh] ?: zh else zh

    fun f(zhFormat: String, vararg args: Any?): String =
        String.format(locale(), t(zhFormat), *args)

    fun locale(): Locale = if (isEnglish) Locale.ENGLISH else Locale.forLanguageTag("zh-Hans")

    private val ENGLISH: Map<String, String> = mapOf(
        // 主屏
        "设置与更多" to "Settings & More",
        "启动中" to "Starting",
        "未连接" to "Offline",
        "可接收" to "Ready",
        "广播未上线" to "Not discoverable",
        "%s，%s，查看连接详情或重命名" to "%s, %s. View connection details or rename",
        "发送到附近" to "Nearby",
        "大文件传输中，请保持 MoonDrop 在前台" to "Large file transfer in progress. Keep MoonDrop open.",
        "重新扫描" to "Scan Again",
        "正在扫描" to "Scanning",
        "正在扫描 · 本次找到 %d 台设备" to "Scanning · %d devices found",
        "正在扫描 · 正在逐个探测局域网地址" to "Scanning · Probing local network addresses",
        "正在扫描局域网" to "Scanning the Local Network",
        "正在逐个探测同网段的设备" to "Probing devices on this network",
        "手动连接" to "Manual",
        "选择设备并发送" to "Choose a device and send",
        "取消" to "Cancel",
        "选择文件" to "Choose File",
        "相册" to "Photos",
        "最近传输" to "Recent",
        "暂无传输记录 · 查看全部" to "No transfers yet · View all",

        // 设置
        "设置" to "Settings",
        "外观" to "Appearance",
        "跟随系统" to "System",
        "浅色" to "Light",
        "深色" to "Dark",
        "语言" to "Language",
        "外观：跟随系统" to "Appearance: System",
        "外观：浅色" to "Appearance: Light",
        "外观：深色" to "Appearance: Dark",
        "语言：简体中文" to "Language: 简体中文",
        "语言：English" to "Language: English",
        "收到的照片自动存入相册" to "Save received photos to Photos automatically",
        "后台接收" to "Background Receiving",
        "去设置" to "Open Settings",
        "已允许" to "Allowed",
        "连接详情" to "Connection",
        "存储位置与常见问题" to "Storage & Help",
        "后台接收，电池优化已关闭" to "Background Receiving, battery optimization is off",
        "后台接收，点按关闭电池优化" to "Background Receiving, tap to turn off battery optimization",
        "已允许后台接收" to "Background receiving is allowed",
        "请在系统设置中关闭 MoonDrop 的电池优化" to
            "Turn off battery optimization for MoonDrop in system settings",
        "尚未允许安装未知应用" to "Installing unknown apps is not allowed yet",

        // 接收状态
        "接收服务还在启动，请稍等" to "The receiving service is still starting. Please wait.",
        "未取得局域网地址，请确认已连接 Wi-Fi" to
            "No local network address. Make sure Wi-Fi is connected.",
        "广播已上线" to "Discoverable",
        "广播未确认，可改用扫描或手动填写 IP" to
            "Discovery not confirmed; try Scan Again or enter the IP manually",
        "已接收：%s" to "Received: %s",
        "已接收并存入相册：%s" to "Received and saved to Photos: %s",
        "接收失败" to "Receive Failed",
        "接收完成" to "Received",

        // 本机 / 连接详情
        "重命名本机" to "Rename This Device",
        "例如 客厅的安卓机" to "e.g. Living room Android",
        "其他设备的 MoonDrop 列表里显示这个名字，最长 %d 个字符。" to
            "Other devices see this name in their MoonDrop list. Up to %d characters.",
        "保存" to "Save",
        "已改名为「%s」" to "Renamed to “%s”",
        "本机名称" to "Device Name",
        "监听端口" to "Listening Port",
        "局域网地址" to "Wi-Fi Address",
        "未连接 Wi-Fi" to "No Wi-Fi connection",
        "广播状态" to "Discovery Status",
        "已上线" to "Online",
        "失败" to "Failed",
        "未确认" to "Unconfirmed",
        "复制地址" to "Copy Address",
        "还没有局域网地址" to "No local network address yet",
        "已复制地址" to "Address copied",

        // 帮助
        "收到的文件放在哪" to "Where received files go",
        "普通文件保存在「下载 / 来自另一台Mac」。\n\n" +
            "开关开启时，图片和视频直接写入「Pictures / MoonDrop」或「Movies / MoonDrop」，" +
            "只保存一份，相册里不会出现重复。关闭开关后媒体留在下载目录，" +
            "可以在记录里点「⋯ → 存入相册」。" to
            "Regular files are saved in “Download / 来自另一台Mac”.\n\n" +
            "When the switch is on, photos and videos go straight to “Pictures / MoonDrop” or " +
            "“Movies / MoonDrop”, written once, so nothing is duplicated in Photos. With the " +
            "switch off, media stays in Downloads; use “⋯ → Save to Photos” in History.",
        "看不见设备怎么办" to "Can't see a device?",
        "确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。Android 设备必须同一 Wi-Fi；" +
            "附近的 Apple 设备即使连着别的网络，也会以「点对点」出现。\n\n" +
            "仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。" to
            "Make sure both sides have MoonDrop open on the same Wi-Fi. Android devices must share " +
            "the same Wi-Fi; nearby Apple devices still show up as “Peer-to-peer” even on another " +
            "network.\n\nIf it is still missing, scan the network or enter the other device's IP " +
            "and port 52345 manually.",
        "接收服务在前台通知里运行，切到后台也能继续接收。关闭电池优化可以减少锁屏后被系统冻结的情况。" to
            "The receiving service runs with a foreground notification so transfers continue in " +
            "the background. Turning off battery optimization reduces freezes after the screen locks.",
        "关于" to "About",
        "MoonDrop %s · 局域网直连，不经过云端。" to
            "MoonDrop %s · Same Wi-Fi direct, never via the cloud.",

        // 手动添加
        "手动添加设备" to "Add Device",
        "IP 地址，例如 192.168.1.20" to "IP address, e.g. 192.168.1.20",
        "端口" to "Port",
        "备注名（可选）" to "Label (optional)",
        "对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。" to
            "The other device must run MoonDrop (Mac / iPhone / Android) on the same network.",
        "连接" to "Connect",
        "请填写 IP 地址" to "Enter an IP address",
        "已添加 %s" to "Added %s",
        "连不上 %s:%d，确认对端在运行且在同一局域网" to
            "Can't reach %s:%d. Make sure MoonDrop is running there on the same network.",
        "没有扫到设备，网络可能开了客户端隔离" to
            "No devices found. The network may have client isolation enabled.",
        "扫描到 %d 台设备" to "Found %d device(s)",

        // 设备列表与发送
        "点对点" to "Peer-to-peer",
        "局域网" to "Same Wi-Fi",
        "手动" to "Manual",
        "点对点直连" to "Peer-to-peer",
        "手动添加" to "Added manually",
        "0 台设备 · 发现后即可发送" to "0 devices · Send once a device appears",
        "%d 台设备，轻点即可发送" to "%d device(s) · Tap to send",
        "%s，%s:%d，点按发送文件" to "%s, %s:%d. Tap to send files",
        "发送到 %s，%s" to "Send to %s, %s",
        "此设备" to "This Device",
        "等待设备出现" to "Waiting for devices",
        "在另一台设备上打开 MoonDrop\n同一 Wi-Fi 下自动发现" to
            "Open MoonDrop on another device\nDevices on the same Wi-Fi appear automatically",
        "发送到 %s" to "Send to %s",
        "设备" to "Device",
        "从相册发送" to "Send from Photos",
        "正在传输，请稍候" to "Transfer in progress. Please wait.",
        "正在发送，完成后可选择新文件" to "Sending. Choose a new file when it finishes.",
        "连接设备后可选择文件或相册" to "Connect a device to choose files or photos",
        "选择文件，%s" to "Choose File, %s",
        "相册，%s" to "Photos, %s",
        "待发送 · %d 个文件" to "Pending · %d file(s)",
        "没有可发送的文件" to "No files to send",
        "读取失败：%s" to "Failed to read: %s",
        "没有可用设备" to "No devices available",
        "发送到哪台设备？" to "Send to which device?",

        // 传输状态
        "正在发送" to "Sending",
        "正在接收" to "Receiving",
        "准备发送…" to "Preparing…",
        "接收中…" to "Receiving…",
        "%s，已完成 %d%%" to "%s, %d%% done",
        "已发送 %d 个文件到 %s" to "Sent %d file(s) to %s",
        "发送完成" to "Sent",
        "发送失败：%s" to "Send Failed: %s",
        "发送失败" to "Send Failed",

        // 传输记录
        "传输记录" to "History",
        "清空" to "Clear",
        "已发送" to "Sent",
        "已接收" to "Received",
        "已发送 %d" to "Sent %d",
        "已接收 %d" to "Received %d",
        "删除全部" to "Delete All",
        "清空记录" to "Clear History",
        "还没有接收文件" to "No received files yet",
        "其他设备发来的文件会出现在这里" to "Files sent from other devices show up here",
        "刷新" to "Refresh",
        "还没有发送记录" to "No sent files yet",
        "发出的文件会按时间出现在这里" to "Files you send show up here by time",
        "%s · 已接收 · %s · %s" to "%s · Received · %s · %s",
        "%s · 已发送至 %s · %s · %s" to "%s · Sent to %s · %s · %s",
        "%d 个文件" to "%d files",
        "最近传输，%s，打开全部传输记录" to "Recent, %s. Open full history",
        "今天" to "Today",
        "昨天" to "Yesterday",
        "更多操作" to "More actions",
        "文件" to "File",
        "安装" to "Install",
        "打开" to "Open",
        "分享" to "Share",
        "存入相册" to "Save to Photos",
        "删除" to "Delete",
        "清空发送记录？" to "Clear sent history?",
        "只清列表，已经发出去的文件不受影响。" to
            "This only clears the list. Files already sent are unaffected.",
        "清空已接收？" to "Clear received files?",
        "「下载 / 来自另一台Mac」里的文件会被删除，无法恢复。已经存入系统相册的图片和视频会保留在相册里，只是从这个列表移除。" to
            "Files in “Download / 来自另一台Mac” will be deleted and cannot be recovered. Photos " +
            "and videos already in the system gallery stay there; they are only removed from " +
            "this list.",
        "没有可打开此文件的应用" to "No app can open this file",
        "文件不可用，可能已被移动或删除" to "File unavailable. It may have been moved or deleted.",

        // 安装 APK
        "需要安装权限" to "Install permission required",
        "系统默认禁止应用安装 APK。请在设置中允许 MoonDrop「安装未知应用」，返回后会自动继续安装。" to
            "Android blocks apps from installing APKs by default. Allow “Install unknown apps” " +
            "for MoonDrop, then come back to continue.",
        "安装包不可用，可能已被移动或删除" to
            "Install package unavailable. It may have been moved or deleted.",
        "没有可用的安装程序" to "No installer available",
        "请手动在系统设置中允许安装未知应用" to
            "Allow installing unknown apps in system settings",
        "分享文件" to "Share file",
        "删除文件？" to "Delete file?",
        "将删除「%s」的实际文件，无法恢复。" to "“%s” will be deleted permanently.",
        "它也会从系统相册中删除。" to "It will also be removed from Photos.",
        "已存入相册：%s" to "Saved to Photos: %s",
        "存入相册失败：%s" to "Save to Photos failed: %s",
        "未知错误" to "Unknown error",

        // 组件
        "关闭" to "Close",

        // 前台服务 / 通知
        "文件接收" to "File Receiving",
        "MoonDrop 正在接收文件" to "MoonDrop is receiving files",
        "等待局域网内的设备发送文件" to "Waiting for nearby devices to send files",
        "接收中 %d%% · %s" to "Receiving %d%% · %s",
        "监听端口 %d · 等待接收文件" to "Listening on port %d · Waiting for files",
        "注册失败：服务名已被占用（会自动换个名字重试）" to
            "Registration failed: name already in use (retrying with a new name)",
        "注册失败：参数不合法（服务名可能含不支持的字符）" to
            "Registration failed: invalid parameters (the name may contain unsupported characters)",
        "注册失败：系统内部错误" to "Registration failed: internal system error",
        "注册失败：超过系统上限" to "Registration failed: system limit reached",
        "注册失败：操作未在运行" to "Registration failed: operation not running",
        "注册失败：代码 %d" to "Registration failed: code %d",

        // 存储 / 传输错误（会显示在结果与提示里）
        "无法创建接收文件" to "Unable to create the received file",
        "无法写入接收文件" to "Unable to write the received file",
        "只有图片和视频能存入相册" to "Only photos and videos can be saved to Photos",
        "无法在相册目录创建文件" to "Unable to create a file in Photos",
        "无法读取已收到的文件" to "Unable to read the received file",
        "无法写入相册目录" to "Unable to write to Photos",
        "无法移除下载目录里的原件" to "Unable to remove the original from Downloads",
        "无法读取 %s" to "Unable to read %s",
        "无法连接对端" to "Unable to reach the device",
        "%s（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）" to
            "%s (the other device may be in the background or offline; open MoonDrop on its screen)"
    )
}
