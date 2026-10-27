import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {

    private static let deviceIDKey = "com.macdrop.mobile.deviceID"
    private static let appGroupID = "group.com.macdrop.mobile"

    let deviceName: String
    let deviceID: String
    let store: FileStore
    let server: TransferServer
    let browser: PeerBrowser

    private let client = TransferClient()

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var listenPort: UInt16 = 0
    @Published var showingDevicePicker = false

    @Published private(set) var sending = false
    @Published private(set) var sendProgress: Double = 0
    @Published private(set) var sendText = ""

    @Published private(set) var receiving = false
    @Published private(set) var receiveProgress: Double = 0
    @Published private(set) var receiveText = ""

    @Published private(set) var received: [ReceivedItem] = []
    @Published private(set) var resultText = ""
    @Published private(set) var resultIsError = false
    @Published private(set) var pendingCount = 0

    @Published var manualError: String?

    private var discovered: [Peer] = []
    private var manual: [Peer] = []
    private var started = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // 从其他 App「用 MoonDrop 打开」进来的文件
    private var pendingURLs: [URL] = []
    private var pendingScopes: [(URL, Bool)] = []
    private var incomingBuffer: [URL] = []
    private var incomingFlushWork: DispatchWorkItem?

    // 发送前临时排队，等用户选完设备再开始
    private var queuedPickedURLs: [URL] = []
    private var pickerForPending = false

    // 从分享扩展回来后自动弹出设备选择，避免用户再进列表里找待发送
    private var autoPickerPending = false
    private var autoPickerTimeout: DispatchWorkItem?

    init() {
        let defaults = UserDefaults.standard
        let sharedDefaults = UserDefaults(suiteName: Self.appGroupID)
        if let saved = defaults.string(forKey: Self.deviceIDKey) {
            deviceID = saved
        } else if let saved = sharedDefaults?.string(forKey: Self.deviceIDKey) {
            deviceID = saved
            defaults.set(saved, forKey: Self.deviceIDKey)
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.deviceIDKey)
            deviceID = generated
        }
        // 分享扩展用同一个 ID 过滤掉本机广播
        sharedDefaults?.set(deviceID, forKey: Self.deviceIDKey)

        let rawName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        deviceName = rawName.isEmpty ? "iPhone" : rawName

        store = FileStore()
        server = TransferServer(deviceName: deviceName, store: store)
        browser = PeerBrowser(ownID: deviceID)

        // 必须在任何 onOpenURL 取回文件之前清，避免误删刚取回的分享副本
        cleanupAbandonedIncoming()

        browser.onPeersChanged = { [weak self] peers in
            Task { @MainActor in self?.applyDiscovered(peers) }
        }
        server.onProgress = { [weak self] fraction, name in
            Task { @MainActor in self?.handleReceiveProgress(fraction, name: name) }
        }
        server.onFinished = { [weak self] url in
            Task { @MainActor in self?.handleReceived(url) }
        }
    }

    func start() {
        guard !started else { return }
        started = true

        server.start(preferredPort: 52345) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.listenPort = port
                    self.browser.advertise(name: self.deviceName, port: port)
                    self.browser.browse()
                    self.refreshReceived()
                case .failure(let error):
                    MobileLog.write("接收服务启动失败：\(error)")
                    self.resultText = "接收服务启动失败：\(error.localizedDescription)"
                    self.resultIsError = true
                }
            }
        }

        handleForeground()
    }

    /// 回到前台时取回分享扩展暂存的文件。
    func handleForeground() {
        if ingestSharedFiles() {
            schedulePendingPicker()
        }
    }

    /// 从 moondrop://incoming 进来：取回文件后直接进入选设备流程。
    func handleSharedLink() {
        _ = ingestSharedFiles()
        guard pendingCount > 0 else { return }
        schedulePendingPicker()
    }

    /// 分享扩展把文件放到 App Group，主 App 启动/回到前台时取回。
    @discardableResult
    func ingestSharedFiles() -> Bool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return false }

        let pendingRoot = container.appendingPathComponent("Pending", isDirectory: true)
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: pendingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        var incoming: [URL] = []
        for session in sessions {
            let values = try? session.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }

            let files = (try? FileManager.default.contentsOfDirectory(
                at: session,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            let targetDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MoonDropIncoming", isDirectory: true)
                .appendingPathComponent(session.lastPathComponent, isDirectory: true)
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

            for file in files {
                let destination = targetDir.appendingPathComponent(file.lastPathComponent)
                if (try? FileManager.default.moveItem(at: file, to: destination)) != nil {
                    incoming.append(destination)
                }
            }
            try? FileManager.default.removeItem(at: session)
        }

        guard !incoming.isEmpty else { return false }
        let known = Set(pendingURLs.map { $0.standardizedFileURL.path })
        let fresh = incoming.filter { !known.contains($0.standardizedFileURL.path) }
        guard !fresh.isEmpty else { return false }

        pendingURLs.append(contentsOf: fresh)
        pendingCount = pendingURLs.count
        resultText = ""
        resultIsError = false
        MobileLog.write("取回分享文件 \(fresh.count) 个，待发送 \(pendingCount) 个")
        return true
    }

    /// 上次异常退出留下的分享副本，启动时清掉。
    private func cleanupAbandonedIncoming() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonDropIncoming", isDirectory: true)
        try? FileManager.default.removeItem(at: root)

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return }
        let pendingRoot = container.appendingPathComponent("Pending", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: pendingRoot,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        for item in items where item.lastPathComponent.hasPrefix(".staging-") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// 只删除分享扩展复制进来的临时副本，外部 App 的 security-scoped 文件不动。
    private func removeIncomingCopies(of urls: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MoonDropIncoming", isDirectory: true)
            .standardizedFileURL
        var sessions = Set<URL>()
        for url in urls {
            let normalized = url.standardizedFileURL
            guard normalized.path.hasPrefix(root.path + "/") else { continue }
            sessions.insert(normalized.deletingLastPathComponent())
        }
        for session in sessions {
            try? FileManager.default.removeItem(at: session)
            MobileLog.write("清理分享副本 \(session.lastPathComponent)")
        }
    }

    // MARK: - 设备

    private func applyDiscovered(_ list: [Peer]) {
        discovered = list
        mergePeers()
    }

    private func mergePeers() {
        var byEndpoint: [String: Peer] = [:]
        for peer in discovered {
            byEndpoint["\(peer.host):\(peer.port)"] = peer
        }
        for peer in manual where byEndpoint["\(peer.host):\(peer.port)"] == nil {
            byEndpoint["\(peer.host):\(peer.port)"] = peer
        }
        peers = byEndpoint.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        presentPendingPickerIfReady()
    }

    /// 分享文件取回后，等设备出现就直接弹选择器；6 秒内没有设备则明确提示。
    private func schedulePendingPicker() {
        guard pendingCount > 0, !sending else { return }
        autoPickerPending = true
        autoPickerTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.autoPickerPending else { return }
            self.autoPickerPending = false
            guard self.pendingCount > 0 else { return }
            if self.peers.isEmpty {
                self.reportError("待发送文件已就绪，但没有发现其他设备。请确认对方已打开 MoonDrop。")
            } else {
                self.sendPending()
            }
        }
        autoPickerTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        presentPendingPickerIfReady()
    }

    private func presentPendingPickerIfReady() {
        guard autoPickerPending, pendingCount > 0, !sending, !peers.isEmpty else { return }
        autoPickerPending = false
        autoPickerTimeout?.cancel()
        autoPickerTimeout = nil
        MobileLog.write("待发送就绪，自动弹出设备选择")
        sendPending()
    }

    @MainActor
    func addManualPeer(host: String, portText: String, name: String) async -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let port = UInt16(portText), port > 0 else {
            manualError = "请填写有效的 IP 地址和端口"
            return false
        }
        guard let url = URL(string: "http://\(trimmedHost):\(port)/macdrop/ping") else {
            manualError = "地址格式不正确"
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reported = object?["device"] as? String
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let peer = Peer(name: trimmedName.isEmpty ? (reported ?? trimmedHost) : trimmedName,
                            host: trimmedHost,
                            port: port,
                            isManual: true)
            manual.removeAll { $0.host == trimmedHost && $0.port == port }
            manual.append(peer)
            mergePeers()
            manualError = nil
            return true
        } catch {
            manualError = "连不上 \(trimmedHost):\(port)，确认对端已运行且在同一局域网"
            return false
        }
    }

    // MARK: - 发送

    /// 选完文件先弹设备选择器；真正发送在 choosePeer 里。
    func requestSend(urls: [URL]) {
        guard !urls.isEmpty, !sending else { return }
        guard !peers.isEmpty else {
            reportError("没有可用设备")
            return
        }
        queuedPickedURLs = urls
        pickerForPending = false
        showingDevicePicker = true
    }

    func choosePeer(_ peer: Peer) {
        showingDevicePicker = false
        if pickerForPending {
            pickerForPending = false
            sendPending(to: peer)
            return
        }
        let urls = queuedPickedURLs
        queuedPickedURLs = []
        guard !urls.isEmpty else { return }
        send(urls: urls, to: peer, scopes: nil)
    }

    func cancelDevicePicker() {
        pickerForPending = false
        queuedPickedURLs = []
        autoPickerPending = false
        autoPickerTimeout?.cancel()
        autoPickerTimeout = nil
    }

    /// 其他 App 通过「用 MoonDrop 打开」传进来的文件。
    /// 多文件可能分多次回调，先短暂聚合再处理。
    func handleIncoming(urls: [URL]) {
        guard !urls.isEmpty else { return }
        incomingBuffer.append(contentsOf: urls)
        incomingFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushIncoming() }
        incomingFlushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func flushIncoming() {
        let urls = incomingBuffer
        incomingBuffer = []
        guard !urls.isEmpty else { return }

        MobileLog.write("收到外部文件：\(urls.map { $0.lastPathComponent }.joined(separator: ", "))")
        for url in urls {
            let started = url.startAccessingSecurityScopedResource()
            pendingScopes.append((url, started))
            pendingURLs.append(url)
        }
        pendingCount = pendingURLs.count
        resultText = ""
        resultIsError = false
        schedulePendingPicker()
    }

    func sendPending() {
        guard !pendingURLs.isEmpty, !sending else { return }
        guard !peers.isEmpty else {
            reportError("没有可用设备")
            return
        }
        queuedPickedURLs = []
        pickerForPending = true
        showingDevicePicker = true
    }

    private func sendPending(to peer: Peer) {
        guard !pendingURLs.isEmpty, !sending else { return }
        let urls = pendingURLs
        let scopes = pendingScopes
        pendingURLs = []
        pendingScopes = []
        pendingCount = 0
        send(urls: urls, to: peer, scopes: scopes) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success:
                    // 发送成功后删掉分享扩展复制进来的临时副本
                    self.removeIncomingCopies(of: urls)
                    MobileLog.write("待发送已清空（\(urls.count) 个）")
                case .failure:
                    // 失败就把文件放回待发送，用户可以直接重试
                    let known = Set(self.pendingURLs.map { $0.standardizedFileURL.path })
                    let restored = urls.filter { !known.contains($0.standardizedFileURL.path) }
                    self.pendingURLs = restored + self.pendingURLs
                    self.pendingScopes = scopes + self.pendingScopes
                    self.pendingCount = self.pendingURLs.count
                }
            }
        }
    }

    func cancelPending() {
        for (url, started) in pendingScopes where started {
            url.stopAccessingSecurityScopedResource()
        }
        removeIncomingCopies(of: pendingURLs)
        pendingScopes = []
        pendingURLs = []
        pendingCount = 0
        autoPickerPending = false
        autoPickerTimeout?.cancel()
        autoPickerTimeout = nil
        resultText = "已取消"
        resultIsError = false
    }

    private func send(urls: [URL], to peer: Peer, scopes: [(URL, Bool)]?,
                      onFinish: ((Result<Void, Error>) -> Void)? = nil) {
        guard !sending else { return }

        let accesses = scopes ?? urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        let files = store.expandForSending(urls: urls)
        guard !files.isEmpty else {
            for (url, started) in accesses where started {
                url.stopAccessingSecurityScopedResource()
            }
            reportError("没有可发送的文件")
            onFinish?(.failure(NSError(domain: "MoonDropMobile", code: 500,
                                      userInfo: [NSLocalizedDescriptionKey: "没有可发送的文件"])))
            return
        }

        sending = true
        sendProgress = 0
        sendText = "准备发送…"
        resultText = ""
        resultIsError = false

        client.send(files: files, to: peer, progress: { [weak self] sent, total, name in
            Task { @MainActor in
                guard let self else { return }
                // 并发时回调可能乱序到达，进度只增不减
                let fraction = total > 0 ? Double(sent) / Double(total) : 0
                self.sendProgress = max(self.sendProgress, fraction)
                self.sendText = "发送中 \(Int(self.sendProgress * 100))% · \(name)"
            }
        }, completion: { [weak self] result in
            for (url, started) in accesses where started {
                url.stopAccessingSecurityScopedResource()
            }
            Task { @MainActor in
                guard let self else { return }
                self.sending = false
                switch result {
                case .success:
                    self.sendProgress = 1
                    self.sendText = ""
                    self.resultText = "已发送 \(files.count) 个文件到 \(peer.name)"
                    self.resultIsError = false
                case .failure(let error):
                    self.sendText = ""
                    self.resultText = "发送失败：\(error.localizedDescription)"
                    self.resultIsError = true
                }
                onFinish?(result)
            }
        })
    }

    func reportError(_ message: String) {
        resultText = message
        resultIsError = true
    }

    // MARK: - 接收

    private func handleReceiveProgress(_ fraction: Double, name: String) {
        receiving = true
        receiveProgress = fraction
        receiveText = "接收中 \(Int(fraction * 100))% · \(name)"
        beginBackgroundTaskIfNeeded()
    }

    private func handleReceived(_ url: URL) {
        receiving = false
        receiveProgress = 1
        receiveText = ""
        resultText = "已接收：\(url.lastPathComponent)"
        resultIsError = false
        refreshReceived()
        endBackgroundTask()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MoonDropReceive") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - 已接收文件

    func refreshReceived() {
        received = store.receivedItems()
    }

    func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: received[index].url)
        }
        refreshReceived()
    }
}
