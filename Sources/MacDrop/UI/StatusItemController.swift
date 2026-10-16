import AppKit

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

    // MARK: - 构建

    func build() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.down.doc.fill", accessibilityDescription: "MacDrop")
            button.image?.isTemplate = true
            button.toolTip = "MacDrop — 跨 Mac 拖放文件"
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

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let head = NSMenuItem(title: "MacDrop · \(cfg.deviceName)", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if peers.isEmpty {
            let none = NSMenuItem(title: "  未发现其他 Mac", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            menu.addItem(.separator())
            let manual = NSMenuItem(title: "手动添加对端…", action: #selector(manualAdd), keyEquivalent: "")
            manual.target = self
            menu.addItem(manual)
        } else {
            let title = NSMenuItem(title: "对端 Mac：", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for peer in peers {
                let item = NSMenuItem(title: "  \(peer.name)  (\(peer.host))",
                                      action: #selector(sendSelection(to:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                item.image = NSImage(systemSymbolName: "arrow.up.right.circle", accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // 通道 C：不依赖拖放
        let sendSel = NSMenuItem(title: "发送 Finder 选中项…",
                                 action: #selector(sendSelectionAction), keyEquivalent: "s")
        sendSel.target = self
        menu.addItem(sendSel)

        let sendFile = NSMenuItem(title: "选择文件发送…",
                                  action: #selector(pickAndSend), keyEquivalent: "o")
        sendFile.target = self
        menu.addItem(sendFile)

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

        let quit = NSMenuItem(title: "退出 MacDrop",
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
            NSAlert(error: NSError(domain: "MacDrop", code: 1, userInfo: [
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
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "发送"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        onSend?(panel.urls, peer)
    }

    @objc private func togglePanel() { panel.toggle() }

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
        alert.informativeText = "在对方 Mac 上打开 MacDrop → 关于/菜单栏 → 查看 IP，或用 ifconfig 获取。\n格式如 192.168.1.23"
        let field = NSTextField(string: "")
        field.placeholderString = "192.168.1.23"
        alert.accessoryView = field
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }

        let port = cfg.port
        bonjour.probeManual(host: host, port: port, name: "手动对端") { ok in
            if !ok {
                NSAlert(error: NSError(domain: "MacDrop", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "连不上 \(host):\(port)，确认对方 MacDrop 在运行、防火墙已放行"
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
        NSLog("[MacDrop] %@", s)
    }
}