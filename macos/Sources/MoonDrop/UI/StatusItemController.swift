import AppKit
import UniformTypeIdentifiers

/// 菜单栏控制器。
///
/// 提供三条通道，其中通道 C 完全不依赖系统拖放：
///   A. 拖到悬浮窗口      → 同机拖放一定可用
///   B. 菜单栏「发送选中项」→ 用 Finder 当前选中，走 Apple Events，完全不依赖拖放
///   C. 菜单栏「发送文件…」  → 手动选文件，同样不依赖拖放
final class StatusItemController: NSObject, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!

    private let cfg = Config.shared
    private var bonjour = BonjourService()
    private var panel = DropPanel.shared

    var onSend: (([URL], Peer) -> Void)?
    var onReceived: ((URL) -> Void)?

    private var peers: [Peer] = []
    private var scanning = false

    // MARK: - 构建

    func build() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: "MoonDrop")
            button.image?.isTemplate = true
            button.toolTip = "MoonDrop — 跨 Mac 拖放文件"
        }

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        panel.build(deviceName: cfg.deviceName)
        panel.onSend = { [weak self] urls, peer in
            self?.onSend?(urls, peer)
        }
        panel.onReceived = { [weak self] url in
            self?.onReceived?(url)
        }

        bonjour.onPeersChanged = { [weak self] peers in
            self?.peers = peers
            self?.panel.updatePeers(peers)
            self?.rebuildMenu()
        }

        bonjour.advertise(name: cfg.deviceName, port: cfg.port)
        bonjour.browse()
    }

    func restartAdvertising() {
        bonjour.stopAdvertising()
        bonjour.advertise(name: cfg.deviceName, port: cfg.port)
        panel.setDeviceName(cfg.deviceName)
    }

    // MARK: - 面板转发（供 AppDelegate 调用）

    func showProgress(_ fraction: Double) { panel.updateProgress(fraction) }
    func showResult(_ text: String, isError: Bool = false) { panel.finishProgress(text: text, isError: isError) }
    func refreshPanelStatus() { panel.refreshStatus() }
    func beginReceive() { panel.beginReceive() }
    func showReceiveProgress(_ fraction: Double) { panel.updateReceiveProgress(fraction) }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let head = NSMenuItem(title: "MoonDrop · \(cfg.deviceName)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let diag = NSMenuItem(title: "  \(diagnosticsSummary())", action: nil, keyEquivalent: "")
        diag.isEnabled = false
        menu.addItem(diag)
        menu.addItem(.separator())

        if peers.isEmpty {
            let none = NSMenuItem(title: "  未发现其他设备", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            let title = NSMenuItem(title: "对端设备：", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for peer in peers {
                let mark = peer.isPeerToPeer ? " · 点对点" : ""
                let item = NSMenuItem(title: "  \(peer.name)\(mark)  (\(peer.host))",
                                      action: #selector(sendSelection(to:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                item.image = NSImage(systemSymbolName: "arrow.up.right.circle", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        let scan = NSMenuItem(title: scanning ? "  扫描局域网中…" : "扫描局域网设备…",
                              action: #selector(scanSubnet), keyEquivalent: "")
        scan.target = self
        scan.isEnabled = !scanning
        menu.addItem(scan)

        let manual = NSMenuItem(title: "手动添加对端…", action: #selector(manualAdd), keyEquivalent: "")
        manual.target = self
        menu.addItem(manual)

        menu.addItem(.separator())

        let rename = NSMenuItem(title: "重命名本机…", action: #selector(renameDevice), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        // 通道 C：不依赖拖放
        let sendSel = NSMenuItem(title: "发送 Finder 选中项…",
                                 action: #selector(sendSelectionAction), keyEquivalent: "s")
        sendSel.target = self
        menu.addItem(sendSel)

        let sendFile = NSMenuItem(title: "选择文件发送…",
                                  action: #selector(pickAndSend), keyEquivalent: "o")
        sendFile.target = self
        menu.addItem(sendFile)

        let sendAlbum = NSMenuItem(title: "从相册发送…",
                                   action: #selector(pickFromAlbumAndSend), keyEquivalent: "")
        sendAlbum.target = self
        menu.addItem(sendAlbum)

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: panel.isVisible ? "隐藏悬浮窗" : "显示悬浮窗",
                                action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let openDir = NSMenuItem(title: "打开接收文件夹",
                                 action: #selector(openDownloadDir), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        let dataDir = NSMenuItem(title: "打开数据目录",
                                 action: #selector(openSupportDir), keyEquivalent: "")
        dataDir.target = self
        dataDir.toolTip = "传输暂存与日志所在位置：\(Config.supportDir.path)"
        menu.addItem(dataDir)

        menu.addItem(.separator())

        let logs = NSMenuItem(title: "传输日志",
                              action: #selector(showLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let clearLogs = NSMenuItem(title: "清空传输记录",
                                   action: #selector(clearTransferLog), keyEquivalent: "")
        clearLogs.target = self
        menu.addItem(clearLogs)

        let quit = NSMenuItem(title: "退出 MoonDrop",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - 动作

    @objc private func sendSelection(to sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let peer = peers.first(where: { $0.id == id }) else { return }
        let urls = FinderBridge.selectedURLs()
        guard !urls.isEmpty else {
            NSAlert(error: NSError(domain: "MoonDrop", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Finder 里没有选中任何文件"
            ])).runModal()
            return
        }
        onSend?(urls, peer)
    }

    @objc private func sendSelectionAction() {
        guard let peer = peers.first else { return }
        let urls = FinderBridge.selectedURLs()
        guard !urls.isEmpty else { return }
        onSend?(urls, peer)
    }

    @objc private func pickAndSend() {
        guard let peer = peers.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "发送"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        onSend?(panel.urls, peer)
    }

    /// 从「照片」图库或磁盘里挑图片/视频发送
    @objc private func pickFromAlbumAndSend() {
        guard let peer = peers.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "发送"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        onSend?(panel.urls, peer)
    }

    @objc private func clearTransferLog() {
        let alert = NSAlert()
        alert.messageText = "清空传输记录？"
        alert.informativeText = "只清空本机的传输日志，已收发的文件不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Logger.clear()
        Logger.write("传输记录已清空")
    }

    @objc private func togglePanel() { panel.toggle() }

    /// 「都在线却互相看不见」时先看这一行：是本机没地址、没广播，还是广播没上线。
    private func diagnosticsSummary() -> String {
        let ips = SubnetScan.localIPv4s().map { $0.0 }
        let address = ips.isEmpty ? "无局域网地址" : ips.joined(separator: ", ")
        let advertise = bonjour.isAdvertiseLive ? "广播已上线"
            : "广播未上线（检查「系统设置→隐私与安全性→本地网络」）"
        return "\(address) · \(advertise)"
    }

    @objc private func renameDevice() {
        let alert = NSAlert()
        alert.messageText = "重命名本机"
        alert.informativeText = "其他设备的 MoonDrop 列表里显示这个名字，最长 24 个字符。"
        let field = NSTextField(string: cfg.deviceName)
        field.placeholderString = "例如 书房的 Mac"
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = String(field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(24))
        guard !name.isEmpty, name != cfg.deviceName else { return }
        cfg.update { $0.deviceName = name }
        restartAdvertising()
        Logger.write("本机改名为 \(name)，已重新广播")
        panel.setDeviceName(name)
    }

    /// Bonjour 之外的兜底：屏蔽组播的网络里靠这个把设备找回来。
    @objc private func scanSubnet() {
        guard !scanning else { return }
        scanning = true
        rebuildMenu()
        Logger.write("开始局域网扫描（默认端口 52345）")
        SubnetScan.run { [weak self] found in
            guard let self else { return }
            self.scanning = false
            for hit in found {
                self.bonjour.addDirect(Peer(host: hit.host, port: hit.port,
                                            name: hit.name, isManual: true))
            }
            Logger.write("局域网扫描命中 \(found.count) 台设备")
            self.rebuildMenu()
            self.panel.finishProgress(text: found.isEmpty
                ? "扫描完成：未发现新设备（可能开了客户端隔离）"
                : "扫描到 \(found.count) 台设备", isError: found.isEmpty)
        }
    }

    @objc private func openDownloadDir() {
        try? cfg.ensureDownloadDir()
        NSWorkspace.shared.open(cfg.downloadURL)
    }

    @objc private func openSupportDir() {
        NSWorkspace.shared.open(Config.supportDir)
    }

    @objc private func manualAdd() {
        let alert = NSAlert()
        alert.messageText = "手动添加对端"
        alert.informativeText = "在对方设备上打开 MoonDrop → 关于/菜单栏 → 查看 IP，或用 ifconfig 获取。\n格式如 192.168.1.23"
        let field = NSTextField(string: "")
        field.placeholderString = "192.168.1.23"
        alert.accessoryView = field
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }

        let port = cfg.port
        bonjour.probeManual(host: host, port: port, name: "") { ok in
            if !ok {
                NSAlert(error: NSError(domain: "MoonDrop", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "连不上 \(host):\(port)，确认对方 MoonDrop 在运行、防火墙已放行"
                ])).runModal()
            }
        }
    }

    @objc private func showLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Logger.logFile.path))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 通过 Apple Events 读取 Finder 选中项。
/// 这是通道 B 的关键 —— 完全不依赖跨机器拖放。
enum FinderBridge {

    private static var script: NSAppleScript? {
        NSAppleScript(source: """
        tell application "Finder"
            set theItems to selection
            set out to ""
            repeat with itm in theItems
                set out to out & (POSIX path of (itm as alias)) & linefeed
            end repeat
            return out
        end tell
        """)
    }

    static func selectedURLs() -> [URL] {
        guard let script else { return [] }
        var err: NSDictionary?
        guard let result = script.executeAndReturnError(&err) as? String else { return [] }
        return result.split(separator: "\n").compactMap {
            let s = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : URL(fileURLWithPath: s)
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// 简单文件日志
enum Logger {
    static var logFile: URL { Config.logFile }

    static func write(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        if let fh = try? FileHandle(forWritingTo: logFile) {
            defer { try? fh.close() }
            try? fh.seekToEnd()
            try? fh.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: logFile)
        }
        NSLog("[MoonDrop] %@", s)
    }

    /// 清空传输记录：只清日志文件，已收发的文件不动
    static func clear() {
        try? Data().write(to: logFile)
    }
}