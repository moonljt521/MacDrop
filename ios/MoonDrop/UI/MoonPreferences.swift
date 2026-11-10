import SwiftUI

/// 应用内语言。只提供两种：简体中文与英文。
/// 中文名与英文名本身就是语言标签，不走翻译。
enum MoonLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }
}

/// 应用内外观。`.system` 跟随系统，其余强制指定。
enum MoonAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return moonT("跟随系统")
        case .light: return moonT("浅色")
        case .dark: return moonT("深色")
        }
    }
}

/// 轻量运行时本地化：语言与外观都存在 UserDefaults，切换后立即生效，
/// 不依赖 .strings/xcstrings，所以动态拼接的模型文案也能跟着变。
final class MoonPreferences: ObservableObject {

    static let shared = MoonPreferences()

    private static let languageKey = "moon.language"
    private static let appearanceKey = "moon.appearance"

    @Published var language: MoonLanguage {
        didSet { defaults.set(language.rawValue, forKey: Self.languageKey) }
    }

    @Published var appearance: MoonAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Self.languageKey)
            .flatMap(MoonLanguage.init(rawValue:)) ?? .zhHans
        appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(MoonAppearance.init(rawValue:)) ?? .system
    }
}

/// 中文原文 → 英文。键必须与源码里的中文一字不差（含标点）。
func moonT(_ zh: String) -> String {
    guard MoonPreferences.shared.language == .en else { return zh }
    return MoonStrings.english[zh] ?? zh
}

/// 带格式的版本：先把中文格式串翻译，再套参数。
func moonTF(_ zhFormat: String, _ args: CVarArg...) -> String {
    String(format: moonT(zhFormat), arguments: args)
}

/// 带数量的版本：英文在 count == 1 时用单数句式，其余与 moonTF 相同。
func moonTP(_ zhFormat: String, _ count: Int, _ args: CVarArg...) -> String {
    var format = moonT(zhFormat)
    if MoonPreferences.shared.language == .en,
       count == 1,
       let singular = MoonStrings.englishSingular[zhFormat] {
        format = singular
    }
    return String(format: format, arguments: [count as CVarArg] + args)
}

/// 结果文案判定：中文原文与英文译文都认，避免切换语言后前缀判断失效。
func moonTextMatches(_ text: String, key zh: String, contains: Bool = false) -> Bool {
    let candidates = [zh, MoonStrings.english[zh]].compactMap { $0 }
    return candidates.contains { contains ? text.contains($0) : text.hasPrefix($0) }
}

enum MoonStrings {

    /// 键为源码中的中文原文。
    static let english: [String: String] = [
        // MARK: 首屏
        "发送到附近": "Nearby",
        "文件，正在抵达": "Files Arriving",
        "接收来自附近": "Receiving from Nearby",
        "操作结果": "Result",
        "准备好，即刻传递": "Ready to Transfer",
        "设备之间直连，不经过云端": "Direct between devices, never through the cloud",
        "每一次传递，都有迹可循": "Every transfer leaves a trace",
        "共享的文件尚未发送，请选择接收设备": "Shared files are waiting. Choose a device to send to.",
        "打开另一台设备上的 MoonDrop": "Open MoonDrop on another device",
        "在另一台设备上打开 MoonDrop": "Open MoonDrop on another device",
        "%d 台设备在附近，轻点开始传递": "%d devices nearby. Tap to start.",
        "%d 个文件待发送": "%d files pending",
        "选择设备并发送": "Choose Device and Send",
        "取消待发送": "Cancel Pending",
        "准备发送…": "Preparing…",
        "接收中…": "Receiving…",
        "设置与更多": "Settings & More",
        "重命名本机": "Rename This Device",
        "连接详情，%@，%@": "Connection, %@, %@",
        "接收启动中": "Starting Receiver",
        "未连接局域网": "No Local Network",
        "可接收": "Ready",
        "广播未上线": "Not Broadcasting",
        "正在扫描": "Scanning",
        "重新扫描": "Scan Again",
        "扫描局域网设备": "Scan the local network for devices",
        "正在扫描局域网设备": "Scanning the local network for devices",
        "已发现 %d 台设备": "%d devices found",
        "正在扫描 · 本次找到 %d 台设备": "Scanning · %d devices found",
        "正在扫描 · 正在逐个探测局域网地址": "Scanning · Probing local network addresses",
        "扫描完成 · 本次找到 %d 台设备": "Scan complete · %d devices found",
        "扫描完成 · 没有发现新设备": "Scan complete · No new devices found",
        "正在扫描局域网": "Scanning the Local Network",
        "正在逐个探测同网段的设备": "Probing devices on this network",
        "手动连接": "Manual",
        "手动添加设备": "Add Device",
        "最近传输": "Recent",
        "传输记录，%@": "History, %@",
        "已接收 · %@": "Received · %@",
        "已发送 · %@ → %@": "Sent · %@ → %@",
        "%d 个文件": "%d files",
        "发送与接收记录，都收在这里": "Sent and received files are here",

        // MARK: 传输记录
        "传输记录": "History",
        "关闭": "Close",
        "清空": "Clear",
        "清空记录": "Clear History",
        "清空已发送记录？": "Clear Sent History?",
        "只清列表，已经发出去的文件不受影响。": "Only the list is cleared. Files already sent are unaffected.",
        "清空已接收？": "Clear Received Files?",
        "删除全部已接收文件": "Delete All Received Files",
        "已接收的文件会从「文件 → 我的 iPhone → MoonDrop → Received」里删除，无法恢复。":
            "Received files will be deleted from Files → On My iPhone → MoonDrop → Received. This can't be undone.",
        "记录类型": "History Type",
        "已发送 %d": "Sent %d",
        "已接收 %d": "Received %d",
        "还没有接收文件": "No Received Files Yet",
        "其他设备发来的文件会按时间出现在这里": "Files from other devices appear here, newest first",
        "还没有发送记录": "No Sent History Yet",
        "发出的文件会按时间出现在这里": "Files you send appear here, newest first",
        "打开文件夹": "Open Folder",
        "打开": "Open",
        "分享": "Share",
        "存入相册": "Save to Photos",
        "删除": "Delete",
        "更多操作": "More",
        "已发送": "Sent",
        "今天": "Today",
        "昨天": "Yesterday",

        // MARK: 设置
        "设置": "Settings",
        "完成": "Done",
        "版本": "Version",
        "外观": "Appearance",
        "语言": "Language",
        "跟随系统": "System",
        "浅色": "Light",
        "深色": "Dark",
        "收到的照片自动存入相册": "Auto-Save Received Photos",
        "连接详情": "Connection",
        "存储位置与常见问题": "Storage & Help",

        // MARK: 手动添加设备
        "对端地址": "Peer Address",
        "IP 地址": "IP Address",
        "端口": "Port",
        "备注名（可选）": "Name (Optional)",
        "连接": "Connect",
        "对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。":
            "The other device needs MoonDrop (Mac, iPhone, or Android) and must be on the same local network.",
        "取消": "Cancel",
        "例如 书房的那台 iPhone": "e.g. Study iPhone",
        "保存": "Save",
        "其他设备的 MoonDrop 列表里显示这个名字，最长 24 个字符。":
            "This name appears in the MoonDrop list on other devices. Up to 24 characters.",
        "发送到哪台设备？": "Send to Which Device?",
        "%@（%@）": "%@ (%@)",

        // MARK: 设备场
        "等待设备出现": "Waiting for Devices",
        "发送到 %@": "Send to %@",
        "点对点直连": "Peer-to-peer",
        "局域网直连": "Same Wi-Fi",
        "此设备": "This Device",
        "选择文件": "Choose File",
        "选择文件发送": "Send a File",
        "相册": "Photos",
        "从相册发送": "Send from Photos",

        // MARK: 传输卡片
        "正在发送": "Sending",
        "正在接收": "Receiving",
        "发送完成": "Sent",
        "接收完成": "Received",
        "发送失败": "Send Failed",
        "操作失败": "Something Went Wrong",
        "大文件传输中，请保持 MoonDrop 在前台；锁屏或切走会中断。":
            "Sending a large file. Keep MoonDrop open; locking the screen or switching apps will interrupt it.",
        "发送到": "Send to",
        "点对点直连 · %@": "Peer-to-peer · %@",

        // MARK: 帮助
        "收到的文件放在哪": "Where Received Files Go",
        "普通文件保存在「文件」App → 我的 iPhone → MoonDrop → Received。开启「自动存入相册」后，图片和视频写入系统相册；同一个文件只会存一次，不会重复。":
            "Files are saved in Files → On My iPhone → MoonDrop → Received. With auto-save on, photos and videos are also written to Photos — each file only once.",
        "看不见设备怎么办": "Can't See a Device?",
        "确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。附近的 Apple 设备即使连着别的网络，也会以「点对点」出现；Android 设备必须同一 Wi-Fi。\n\n仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。":
            "Make sure MoonDrop is open on both devices and both are on the same Wi-Fi. Nearby Apple devices appear as Peer-to-peer even on another network; Android devices must share the Wi-Fi.\n\nStill nothing? Scan the local network, or enter the other device's IP and port 52345.",
        "后台接收": "Background Receiving",
        "接收过程中请保持 MoonDrop 在前台，锁屏或长时间切到后台可能中断传输。iPhone 切到后台会停止广播，回到前台会自动恢复。":
            "Keep MoonDrop open while receiving. Locking the screen or staying in the background may interrupt the transfer. In the background, iPhone stops advertising and resumes automatically when you return.",
        "关于": "About",
        "MoonDrop %@ · 局域网直连，不经过云端。": "MoonDrop %@ · Direct over the local network, no cloud.",

        // MARK: 连接详情
        "本机名称": "Device Name",
        "监听端口": "Listening Port",
        "启动中": "Starting",
        "局域网地址": "Local Address",
        "广播状态": "Advertising",
        "未连接 Wi-Fi": "No Wi-Fi",
        "接收服务启动中": "Receiver Starting",
        "已上线": "Live",
        "未确认": "Unconfirmed",
        "接收服务还在启动，请稍等。": "The receiver is still starting. Please wait.",
        "未取得局域网地址，请确认已连接 Wi-Fi。": "No local address yet. Make sure Wi-Fi is connected.",
        "广播未确认。请在「设置 → 隐私与安全性 → 本地网络」允许 MoonDrop，或改用扫描 / 手动填写 IP。":
            "Advertising is unconfirmed. Allow MoonDrop in Settings → Privacy & Security → Local Network, or scan or enter the IP manually.",
        "其他设备可以在同一 Wi-Fi 下直接看到本机。": "Other devices on the same Wi-Fi can see this device.",
        "复制地址": "Copy Address",
        "已复制": "Copied",

        // MARK: 预览
        "关闭预览": "Close Preview",

        // MARK: 运行状态与错误
        "接收服务启动失败：%@": "Couldn't Start Receiver: %@",
        "待发送文件已就绪，但没有发现其他设备。请确认对方已打开 MoonDrop。":
            "Files are ready, but no other device was found. Make sure MoonDrop is open on the other device.",
        "请填写有效的 IP 地址和端口": "Enter a valid IP address and port",
        "地址格式不正确": "Invalid address",
        "连不上 %@:%d，确认对端已运行且在同一局域网":
            "Can't reach %@:%d. Make sure the other device is running MoonDrop on the same network.",
        "已改名为「%@」": "Renamed to “%@”",
        "扫描完成：没有发现设备，网络可能开了客户端隔离":
            "Scan Complete: No Devices Found. The network may isolate clients.",
        "没有可用设备": "No Devices Available",
        "已取消": "Canceled",
        "没有可发送的文件": "No Files to Send",
        "发送中 %d%% · %@": "Sending %d%% · %@",
        "已发送 %d 个文件到 %@": "Sent %d files to %@",
        "发送失败：%@": "Send Failed: %@",
        "接收中 %d%% · %@": "Receiving %d%% · %@",
        "已接收：%@": "Received: %@",
        "已接收并存入相册：%@": "Received and Saved to Photos: %@",
        "已接收，但存入相册失败：%@": "Received, but Couldn't Save to Photos: %@",
        "已经在相册里了：%@": "Already in Photos: %@",
        "已存入相册：%@": "Saved to Photos: %@",
        "没能读取所选照片": "Couldn't Read the Selected Photos",
        "相册-%@.%@": "Photos-%@.%@",

        // MARK: 相册写入
        "只有图片和视频能存入相册": "Only photos and videos can be saved to Photos",
        "文件已不存在": "The file no longer exists",
        "没有相册写入权限，请在「设置 → MoonDrop → 照片」里允许":
            "No permission to add to Photos. Allow it in Settings → MoonDrop → Photos.",
        "存入相册失败": "Couldn't Save to Photos",

        // MARK: 接收端 / 发送端
        "文件不完整：已收 %lld / %lld 字节": "Incomplete file: received %lld of %lld bytes",
        "读取文件时提前结束": "File ended unexpectedly while reading",
        "%@（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）":
            "%@ (The other device may be in the background or offline. Open MoonDrop on its screen.)"
    ]

    /// 英文单数句式；键与主表一致，只补数量为 1 时读起来别扭的几句。
    static let englishSingular: [String: String] = [
        "已发送 %d 个文件到 %@": "Sent %d file to %@",
        "%d 个文件待发送": "%d file pending",
        "%d 台设备在附近，轻点开始传递": "%d device nearby. Tap to start.",
        "已发现 %d 台设备": "%d device found",
        "正在扫描 · 本次找到 %d 台设备": "Scanning · %d device found",
        "扫描完成 · 本次找到 %d 台设备": "Scan complete · %d device found"
    ]
}
