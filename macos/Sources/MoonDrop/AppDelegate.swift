import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let cfg = Config.shared
    private var http: HTTPService?
    private var status: StatusItemController!
    private let engine = TransferEngine.shared

    /// 一条在途接收的元信息
    private struct ReceiveMeta {
        var name: String
        var path: String
        var root: String
        var total: Int64
    }

    /// HTTP 服务是并发线程，路由里对以下状态都必须加锁
    private let stateLock = NSLock()
    private var pendingMeta: [String: ReceiveMeta] = [:]
    /// 每个传输已落盘字节数：分块乱序到达，用它累加进度才不会来回跳
    private var receivedBytes: [String: Int64] = [:]
    /// 已计入进度的分块 offset：发送端重试会重发同一块，不能重复累加
    private var receivedOffsets: [String: Set<Int64>] = [:]
    /// 接收进度节流：只有整数百分比变化才刷新 UI
    private var lastRecvPercent: [String: Int] = [:]
    /// 最后一次收到数据的时间，看门狗靠它判定断流
    private var lastActivity: [String: Date] = [:]
    private var watchdog: DispatchSourceTimer?

    /// 发送端进程被系统回收（典型：iOS 分享扩展）后，TCP 可能悄悄断掉、
    /// 一个分块也不会再来。超过这个时间没有任何新分块就判定为中断。
    private static let receiveIdleTimeout: TimeInterval = 20

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        try? cfg.ensureDownloadDir()
        takeOverRunningInstances()
        cleanupStaleStaging()
        Logger.write("MoonDrop 启动，设备名=\(cfg.deviceName)，端口=\(cfg.port)，接收目录=\(cfg.downloadDir)")

        startServer()
        startReceiveWatchdog()

        status = StatusItemController()
        status.build()
        status.onSend = { [weak self] urls, peer in
            self?.send(urls, to: peer)
        }
        status.onReceived = { [weak self] url in
            Logger.write("收到文件：\(url.path)")
            self?.notifyReceived(url)
        }

        installUIProbeIfNeeded()
    }

    /// 测试钩子：MACDROP_UI_PROBE=<目录> 时，按顺序输出收起 / 展开两种状态的
    /// 面板快照到该目录，用于没有「屏幕录制」权限的环境自查 UI。
    /// 正常运行时该环境变量不存在，此方法直接返回，不影响任何功能。
    private func installUIProbeIfNeeded() {
        guard let dir = ProcessInfo.processInfo.environment["MACDROP_UI_PROBE"] else { return }
        let panel = DropPanel.shared
        // 每个状态保持约 2.5 秒，外部截图工具也能抓到
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            panel.debugSnapshot(to: dir + "/collapsed.png")
            Logger.write("UI 探针：收起态（保持到 4.5s）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            panel.debugForceHover(true)
            Logger.write("UI 探针：悬停态（保持到 8.0s）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
            panel.debugSnapshot(to: dir + "/hover.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            panel.debugForceHover(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) {
            panel.updateProgress(0.42)
            Logger.write("UI 探针：展开进度态（保持到 12.0s）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.5) {
            panel.debugSnapshot(to: dir + "/expanded.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.5) {
            panel.finishProgress(text: "已发送 demo.txt")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) {
            panel.debugShowPicker()
            Logger.write("UI 探针：多设备选择器态（保持到 16.0s）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.5) {
            panel.debugSnapshot(to: dir + "/picker.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16.5) {
            panel.debugCancelPicker()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 17.5) {
            panel.beginReceive()
            Logger.write("UI 探针：接收开始态（保持到 20.5s）")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18.2) {
            panel.updateReceiveProgress(0.35)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 19.0) {
            panel.debugSnapshot(to: dir + "/receive.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 19.5) {
            panel.updateReceiveProgress(0.80)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.5) {
            panel.finishProgress(text: "已接收：合同扫描件.pdf")
            Logger.write("UI 探针：结束")
        }
    }

    /// 清掉上次异常退出留下的半截文件。
    /// 这些是传输中途断掉的临时文件，正常情况下 finishReceive 已把它们移走。
    private func cleanupStaleStaging() {
        let dir = Config.stagingDir
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        guard !items.isEmpty else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
        Logger.write("清理残留暂存文件 \(items.count) 个")
    }

    func applicationWillTerminate(_ notification: Notification) {
        http?.stop()
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: - 接收看门狗

    /// 断流检测：接收中长时间没有新分块，就清掉暂存并把面板从「接收中 x%」里救出来。
    /// 之前发送端（iOS 分享扩展被系统回收）一消失，面板会永远停在那儿，只能重启 App。
    private func startReceiveWatchdog() {
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.macdrop.recv.watchdog")
        )
        timer.schedule(deadline: .now() + Self.receiveIdleTimeout, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sweepStalledReceives() }
        timer.resume()
        watchdog = timer
    }

    private func sweepStalledReceives() {
        let deadline = Date().addingTimeInterval(-Self.receiveIdleTimeout)

        stateLock.lock()
        let stalled = lastActivity.filter { $0.value < deadline }.map { $0.key }
        var victims: [(id: String, meta: ReceiveMeta, done: Int64)] = []
        for id in stalled {
            if let meta = pendingMeta.removeValue(forKey: id) {
                victims.append((id, meta, receivedBytes[id] ?? 0))
            }
            receivedBytes.removeValue(forKey: id)
            receivedOffsets.removeValue(forKey: id)
            lastRecvPercent.removeValue(forKey: id)
            lastActivity.removeValue(forKey: id)
        }
        stateLock.unlock()

        for victim in victims {
            endReceive(victim.id, meta: victim.meta, received: victim.done,
                       reason: "超过 \(Int(Self.receiveIdleTimeout)) 秒没有新分块")
        }
    }

    /// 中断一条接收：删暂存、写日志、面板报错（否则界面会一直停在最后一个百分比）
    private func endReceive(_ id: String, meta: ReceiveMeta?, received: Int64,
                            reason: String) {
        engine.cancelReceive(transferID: id)

        let total = meta?.total ?? 0
        let percent = total > 0 ? Int(min(100, received * 100 / total)) : 0
        let name = meta?.name ?? id
        Logger.write("接收中断 \(name)：已收 \(received)/\(total) 字节（\(percent)%），\(reason)")

        DispatchQueue.main.async { [weak self] in
            self?.status.showResult("接收中断（已收 \(percent)%）", isError: true)
        }
    }

    // MARK: - 新版接管旧实例

    /// 启动时若发现同名 App 的旧实例还在运行（比如用户直接把新版本覆盖上去后双击），
    /// 自动请它退出，避免两个实例抢端口 / 菜单栏出现两个图标。
    /// 优先走本机 HTTP 通道（优雅退出、不需要任何权限弹窗），超时再强制结束。
    /// 测试模式（MACDROP_RECV_DIR 环境变量，多实例）不接管。
    private func takeOverRunningInstances() {
        guard ProcessInfo.processInfo.environment["MACDROP_RECV_DIR"] == nil,
              let bundleID = Bundle.main.bundleIdentifier else { return }

        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard !others.isEmpty else { return }

        Logger.write("发现 \(others.count) 个正在运行的旧实例，自动替换…")

        askOldInstanceToQuit()

        if !waitForExit(others, timeout: 1.5) {
            for app in others where !isGone(app) {
                Logger.write("旧实例未响应，强制结束 pid=\(app.processIdentifier)")
                app.forceTerminate()
            }
            _ = waitForExit(others, timeout: 1.5)
        }
        Logger.write("旧实例已退出，新版本接管完成")
    }

    /// 请求本机旧实例自己退出。旧版本没有这个接口时只会拿到 404，很快超时。
    private func askOldInstanceToQuit() {
        guard let url = URL(string: "http://127.0.0.1:\(cfg.port)/macdrop/quit") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.5
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2)
    }

    @discardableResult
    private func waitForExit(_ apps: [NSRunningApplication], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if apps.allSatisfy({ isGone($0) }) { return true }
            usleep(80_000)
        }
        return apps.allSatisfy({ isGone($0) })
    }

    /// isTerminated 的通知可能滞后，用 kill(pid, 0) 直接探测进程是否还在
    private func isGone(_ app: NSRunningApplication) -> Bool {
        app.isTerminated || kill(app.processIdentifier, 0) != 0
    }

    // MARK: - HTTP 路由

    private func startServer() {
        let port = cfg.port
        http = HTTPService(port: port) { [weak self] req in
            guard let self else { return .failure("server stopped", status: 500) }
            return self.route(req)
        }
        do {
            try http?.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "端口 \(port) 无法监听"
            alert.informativeText = """
            \(error.localizedDescription)

            可能是端口被占用。可以在设置里改端口，或先用下面命令找出占用者：
            lsof -nP -iTCP:\(port) -sTCP:LISTEN
            """
            alert.addButton(withTitle: "改用随机端口")
            alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn {
                let alt = UInt16.random(in: 40000...60000)
                self.cfg.update { $0.port = alt }
                self.status?.restartAdvertising()
                self.startServer()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func route(_ req: HTTPService.Request) -> HTTPService.Response {
        switch (req.method, req.path) {

        case ("GET", "/macdrop/ping"):
            return .json(["device": cfg.deviceName, "version": 1, "port": cfg.port])

        case ("POST", "/macdrop/begin"):
            guard let id = req.query["id"],
                  let name = req.query["name"],
                  let sizeStr = req.query["size"],
                  let size = Int64(sizeStr) else {
                return .failure("缺少参数")
            }
            do {
                try engine.beginReceive(transferID: id, fileName: name, total: size)
                stateLock.lock()
                pendingMeta[id] = ReceiveMeta(name: name,
                                              path: req.query["path"] ?? "",
                                              root: req.query["root"] ?? "",
                                              total: size)
                receivedBytes[id] = 0
                receivedOffsets[id] = []
                lastRecvPercent[id] = -1
                lastActivity[id] = Date()
                stateLock.unlock()
                Logger.write("开始接收 \(name)（\(size) 字节）")
                DispatchQueue.main.async { [weak self] in
                    self?.status.beginReceive()
                }
                return .json(["ok": true])
            } catch {
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/chunk"):
            guard let id = req.query["id"],
                  let offStr = req.query["offset"],
                  let offset = Int64(offStr) else {
                return .failure("缺少参数")
            }
            do {
                try engine.appendChunk(transferID: id, offset: offset, data: req.body)
                stateLock.lock()
                let total = pendingMeta[id]?.total ?? 0
                // 重试会重发同一个 offset，只计一次
                let isNewOffset = receivedOffsets[id, default: []].insert(offset).inserted
                if isNewOffset {
                    receivedBytes[id] = (receivedBytes[id] ?? 0) + Int64(req.body.count)
                }
                let done = receivedBytes[id] ?? 0
                lastActivity[id] = Date()
                let percent = total > 0 ? Int(min(100, done * 100 / total)) : 0
                let changed = percent != lastRecvPercent[id]
                if changed { lastRecvPercent[id] = percent }
                stateLock.unlock()
                if changed {
                    DispatchQueue.main.async { [weak self] in
                        self?.status.showReceiveProgress(Double(percent) / 100)
                    }
                }
                return .json(["ok": true])
            } catch {
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/finish"):
            guard let id = req.query["id"] else { return .failure("缺少参数") }
            stateLock.lock()
            let meta = pendingMeta.removeValue(forKey: id)
            receivedBytes.removeValue(forKey: id)
            receivedOffsets.removeValue(forKey: id)
            lastRecvPercent.removeValue(forKey: id)
            lastActivity.removeValue(forKey: id)
            stateLock.unlock()
            do {
                let dest = try engine.finishReceive(transferID: id,
                                                    fileName: meta?.name ?? id,
                                                    relativePath: meta?.path,
                                                    rootName: meta?.root,
                                                    expectedSize: meta?.total)
                Logger.write("接收完成 → \(dest.path)")
                DispatchQueue.main.async { [weak self] in
                    self?.status.showResult("已接收：\(dest.lastPathComponent)")
                    self?.status.onReceived?(dest)
                }
                return .json(["ok": true, "path": dest.path])
            } catch {
                engine.cancelReceive(transferID: id)
                DispatchQueue.main.async { [weak self] in
                    self?.status.showResult("接收失败", isError: true)
                }
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/quit"):
            // 仅供本机新实例启动时「接管」使用，禁止局域网其他机器调用
            guard req.isLocalConnection else {
                return .failure("仅允许本机调用", status: 403)
            }
            Logger.write("收到本机退出请求（新版接管），正在退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                NSApp.terminate(nil)
            }
            return .json(["ok": true])

        case ("POST", "/macdrop/abort"):
            if let id = req.query["id"] {
                engine.cancelReceive(transferID: id)
                stateLock.lock()
                pendingMeta.removeValue(forKey: id)
                receivedBytes.removeValue(forKey: id)
                receivedOffsets.removeValue(forKey: id)
                lastRecvPercent.removeValue(forKey: id)
                lastActivity.removeValue(forKey: id)
                stateLock.unlock()
            }
            return .json(["ok": true])

        default:
            return .failure("未知接口", status: 404)
        }
    }

    // MARK: - 发送

    private func send(_ urls: [URL], to peer: Peer) {
        let items = engine.expand(urls: urls)
        guard !items.isEmpty else { return }

        let total = items.reduce(Int64(0)) { $0 + $1.size }
        Logger.write("发送到 \(peer.name)：\(items.count) 个文件，\(total) 字节")

        status.refreshPanelStatus()
        engine.send(items: items, to: peer,
                    progress: { p in
            DispatchQueue.main.async {
                self.status.showProgress(p.fraction)
            }
        }, completion: { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    let names = items.first?.url.lastPathComponent ?? ""
                    let more = items.count > 1 ? " 等 \(items.count) 个文件" : ""
                    self.status.showResult("已发送 \(names)\(more)")
                    Logger.write("发送完成 → \(peer.name)")
                case .failure(let err):
                    self.status.showResult("发送失败：\(err.localizedDescription)", isError: true)
                    Logger.write("发送失败：\(err)\(self.connectHint(for: err))")
                }
            }
        })
    }

    private func notifyReceived(_ url: URL) {
        if cfg.current.autoAccept {
            FinderBridge.reveal(url)
        }
    }

    /// 连接类错误给一句排查提示（只写日志，面板保持简短）
    private func connectHint(for error: Error) -> String {
        guard let u = error as? URLError else { return "" }
        switch u.code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut,
             .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
            return "\n  提示：对端可能未运行或在睡眠；确认两台在同一 Wi-Fi；"
                 + "系统设置→隐私与安全性→本地网络 中允许 MoonDrop"
        default:
            return ""
        }
    }
}