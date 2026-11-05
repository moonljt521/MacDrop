import Foundation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {

    private static let deviceIDKey = "com.macdrop.mobile.deviceID"
    private static let deviceNameKey = "com.macdrop.mobile.deviceName"
    private static let autoSaveKey = "com.macdrop.mobile.autoSavePhotos"
    private static let savedPhotosKey = "com.macdrop.mobile.savedPhotoPaths"
    private static let sentKey = "com.macdrop.mobile.sentRecords"
    private static let appGroupID = "group.com.macdrop.mobile"

    @Published var deviceName: String
    let deviceID: String
    let store: FileStore
    let server: TransferServer
    let browser: PeerBrowser

    private let client = TransferClient()
    private let defaults = UserDefaults.standard

    @Published private(set) var peers: [Peer] = []
    @Published private(set) var listenPort: UInt16 = 0
    @Published var showingDevicePicker = false
    @Published private(set) var scanning = false
    /// 收到的图片/视频自动写进系统相册
    @Published var autoSaveToPhotos: Bool {
        didSet { defaults.set(autoSaveToPhotos, forKey: Self.autoSaveKey) }
    }

    /// 已经写入系统相册的文件路径。PHAsset 每次保存都会新建一个资源，自动保存和手动
    /// 「存入相册」必须共用这份记录，否则用户点一下按钮相册里就会多出一张一样的照片。
    @Published private(set) var savedPhotoPaths: Set<String> = [] {
        didSet { defaults.set(Array(savedPhotoPaths), forKey: Self.savedPhotosKey) }
    }

    @Published private(set) var sending = false
    @Published private(set) var sendProgress: Double = 0
    @Published private(set) var sendText = ""
    @Published private(set) var sendLargeFile = false

    @Published private(set) var receiving = false
    @Published private(set) var receiveProgress: Double = 0
    @Published private(set) var receiveText = ""

    @Published private(set) var received: [ReceivedItem] = []
    @Published private(set) var sentRecords: [SentRecord] = []
    @Published private(set) var resultText = ""
    @Published private(set) var resultIsError = false
    @Published private(set) var pendingCount = 0

    @Published var manualError: String?

    private var discovered: [Peer] = []
    private var manual: [Peer] = []
    private var started = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 发送期间单独申请的后台时间（跟接收分开放，互不影响）
    private var sendBackgroundTask: UIBackgroundTaskIdentifier = .invalid

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
        let savedName = defaults.string(forKey: Self.deviceNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initialName = (savedName?.isEmpty == false) ? savedName! : (rawName.isEmpty ? "iPhone" : rawName)
        deviceName = initialName
        autoSaveToPhotos = defaults.object(forKey: Self.autoSaveKey) as? Bool ?? true
        savedPhotoPaths = Set(defaults.stringArray(forKey: Self.savedPhotosKey) ?? [])
        sentRecords = AppModel.loadSentRecords(from: defaults)

        // 属性包装器（@Published）在 self 完全初始化前不能读，这里一律用局部常量
        let fileStore = FileStore()
        store = fileStore
        server = TransferServer(deviceName: initialName, store: fileStore)
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
    /// 另外必须重新广播：系统把 App 挂起时会收回 Bonjour 发布，
    /// 不重发就出现「本机一切正常、别的设备却再也看不到它」。
    func handleForeground() {
        if started, listenPort > 0 {
            browser.restart()
        }
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

    // MARK: - 本机名称

    /// 自定义本机在别的设备列表里显示的名字
    func rename(to rawName: String) {
        let trimmed = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !trimmed.isEmpty else { return }
        guard trimmed != deviceName else { return }
        deviceName = trimmed
        defaults.set(trimmed, forKey: Self.deviceNameKey)
        server.deviceName = trimmed
        if listenPort > 0 {
            browser.advertise(name: trimmed, port: listenPort)
        }
        MobileLog.write("本机改名为 \(trimmed)，已重新广播")
        resultText = "已改名为「\(trimmed)」"
        resultIsError = false
    }

    // MARK: - 连接自查

    /// 本机局域网地址；为空说明还没连上 Wi-Fi
    var localAddresses: [String] { SubnetScan.localIPv4s() }
    var isAdvertiseLive: Bool { browser.isAdvertiseLive }

    /// Bonjour 之外的兜底：组播被屏蔽的网络里靠这个把设备找回来。
    func scanSubnet() {
        guard !scanning else { return }
        scanning = true
        MobileLog.write("开始局域网扫描（默认端口 52345）")
        SubnetScan.run { [weak self] found in
            guard let self else { return }
            self.scanning = false
            for hit in found {
                self.browser.addDirect(Peer(name: hit.name, host: hit.host,
                                            port: hit.port, isManual: true))
            }
            self.manualError = nil
            self.resultText = found.isEmpty
                ? "扫描完成：没有发现设备，网络可能开了客户端隔离"
                : "扫描到 \(found.count) 台设备"
            self.resultIsError = found.isEmpty
            MobileLog.write("扫描命中 \(found.count) 台")
        }
    }

    // MARK: - 发送

    /// 选完文件先弹设备选择器；真正发送在 choosePeer 里。
    /// 从设备行进入时已经确定了目标，直接开传。
    func requestSend(urls: [URL], to peer: Peer? = nil) {
        guard !urls.isEmpty, !sending else { return }
        if let peer {
            send(urls: urls, to: peer, scopes: nil)
            return
        }
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

        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        sending = true
        sendProgress = 0
        sendText = "准备发送…"
        sendLargeFile = totalBytes > 100 * 1024 * 1024
        resultText = ""
        resultIsError = false

        // 大文件要跑几十秒到几分钟：这期间别让屏幕自动锁屏，
        // 也争取一点后台时间，避免用户切一下 App 回来发现传输已经断了
        UIApplication.shared.isIdleTimerDisabled = true
        beginSendBackgroundTask()

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
                UIApplication.shared.isIdleTimerDisabled = false
                guard let self else { return }
                self.endSendBackgroundTask()
                self.sending = false
                self.sendLargeFile = false
                switch result {
                case .success:
                    self.sendProgress = 1
                    self.sendText = ""
                    self.resultText = "已发送 \(files.count) 个文件到 \(peer.name)"
                    self.resultIsError = false
                    self.recordSent(names: files.map { $0.relativePath },
                                    target: peer.name, size: totalBytes)
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

    /// 结果条 5 秒（失败 8 秒）后自动收起；只清掉同一条，避免误删新结果
    func dismissResult(expected text: String) {
        guard resultText == text else { return }
        resultText = ""
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
        if autoSaveToPhotos, PhotoSaver.isMedia(url) {
            PhotoSaver.save(url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.markSavedToPhotos(url)
                    self.resultText = "已接收并存入相册：\(url.lastPathComponent)"
                    self.resultIsError = false
                case .failure(let error):
                    self.resultText = "已接收，但存入相册失败：\(error.localizedDescription)"
                    self.resultIsError = true
                }
            }
        }
    }

    func didSaveToPhotos(_ item: ReceivedItem) -> Bool {
        savedPhotoPaths.contains(item.url.path)
    }

    private func markSavedToPhotos(_ url: URL) {
        savedPhotoPaths.insert(url.path)
    }

    /// 手动把已接收的图片/视频存进相册；已经存过的直接拒绝，避免重复插入 PHAsset
    func saveToPhotos(_ item: ReceivedItem) {
        guard !didSaveToPhotos(item) else {
            resultText = "已经在相册里了：\(item.name)"
            resultIsError = false
            return
        }
        PhotoSaver.save(item.url) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.markSavedToPhotos(item.url)
                self.resultText = "已存入相册：\(item.name)"
                self.resultIsError = false
            case .failure(let error):
                self.reportError(error.localizedDescription)
            }
        }
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

    private func beginSendBackgroundTask() {
        guard sendBackgroundTask == .invalid else { return }
        sendBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MoonDropSend") { [weak self] in
            Task { @MainActor in self?.endSendBackgroundTask() }
        }
    }

    private func endSendBackgroundTask() {
        guard sendBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(sendBackgroundTask)
        sendBackgroundTask = .invalid
    }

    // MARK: - 已接收文件

    func refreshReceived() {
        received = store.receivedItems()
    }

    func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            savedPhotoPaths.remove(received[index].url.path)
            try? FileManager.default.removeItem(at: received[index].url)
        }
        refreshReceived()
    }

    /// 单条删除：记录按天分组后 IndexSet 对不上，用条目本身定位
    func delete(_ item: ReceivedItem) {
        savedPhotoPaths.remove(item.url.path)
        try? FileManager.default.removeItem(at: item.url)
        refreshReceived()
    }

    /// 清空已接收：删掉文件本身，只留空列表
    func clearReceived() {
        savedPhotoPaths = []
        store.clearReceived()
        refreshReceived()
    }

    // MARK: - 已发送记录

    private static func loadSentRecords(from defaults: UserDefaults) -> [SentRecord] {
        guard let data = defaults.data(forKey: sentKey),
              let records = try? JSONDecoder().decode([SentRecord].self, from: data)
        else { return [] }
        return records
    }

    private func persistSentRecords() {
        if let data = try? JSONEncoder().encode(sentRecords) {
            defaults.set(data, forKey: Self.sentKey)
        }
    }

    /// 记一笔发送成功的流水
    func recordSent(names: [String], target: String, size: Int64) {
        let record = SentRecord(names: names, target: target, size: size, date: Date())
        sentRecords.insert(record, at: 0)
        if sentRecords.count > 200 {
            sentRecords.removeLast(sentRecords.count - 200)
        }
        persistSentRecords()
        MobileLog.write("记录发送：\(names.count) 个文件 → \(target)")
    }

    /// 只清流水，文件本身不动
    func clearSentRecords() {
        sentRecords.removeAll()
        persistSentRecords()
    }

    // MARK: - 从相册发送

    /// 相册里选中的图片/视频：先落成临时文件，再走原来的发送流程
    func sendFromAlbum(_ items: [PhotosPickerItem], to peer: Peer? = nil) {
        guard !items.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for item in items {
                if let media = try? await item.loadTransferable(type: PickedMedia.self) {
                    urls.append(media.url)
                    continue
                }
                // 兜底：拿不到文件就按图片数据处理
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("相册-\(UUID().uuidString).\(ext)")
                do {
                    try data.write(to: dest)
                    urls.append(dest)
                } catch {
                    continue
                }
            }
            guard !urls.isEmpty else {
                reportError("没能读取所选照片")
                return
            }
            requestSend(urls: urls, to: peer)
        }
    }
}
