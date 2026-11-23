import Foundation

struct ReceiveConfirmation: Identifiable {
    let batchID: String
    let senderName: String
    let fileCount: Int
    let totalBytes: Int64
    let firstName: String
    var id: String { batchID }
}

struct ReceiveProgress {
    let id: String
    let name: String
    let received: Int64
    let total: Int64
}

struct ReceiveStopped {
    let id: String
    let name: String
    let reason: String
}

final class TransferServer {
    private struct Meta {
        var name: String
        var path: String
        var root: String
        var total: Int64
    }

    private struct Begin {
        let id: String
        let meta: Meta
        let batchID: String
    }

    private struct Batch {
        let confirmation: ReceiveConfirmation
        var accepted: Bool?
        var touched: Date
        var created: Date
    }

    private final class Entry {
        let url: URL
        let meta: Meta
        let lock = NSLock()
        var offsets: Set<Int64> = []
        var receivedBytes: Int64 = 0
        var lastPercent = -1
        var lastActivity = Date()

        init(url: URL, meta: Meta) {
            self.url = url
            self.meta = meta
        }
    }

    private let store: FileStore
    private var http: HTTPServer?
    private var staging: [String: Entry] = [:]
    private var pending: [String: Begin] = [:]
    private var batches: [String: Batch] = [:]
    private let lock = NSLock()
    private var lastError: Error?
    private var watchdog: DispatchSourceTimer?
    private let nameLock = NSLock()
    private var storedName: String

    var deviceName: String {
        get {
            nameLock.lock()
            defer { nameLock.unlock() }
            return storedName
        }
        set {
            nameLock.lock()
            storedName = newValue
            nameLock.unlock()
        }
    }

    private(set) var port: UInt16 = 0
    var onProgress: ((ReceiveProgress) -> Void)?
    var onFinished: ((String, URL) -> Void)?
    var onStopped: ((ReceiveStopped) -> Void)?
    var onConfirm: ((ReceiveConfirmation) -> Void)?
    var onConfirmationResolved: ((String) -> Void)?

    init(deviceName: String, store: FileStore) {
        self.storedName = deviceName
        self.store = store
    }

    func start(preferredPort: UInt16 = 52345, completion: @escaping (Result<UInt16, Error>) -> Void) {
        startWatchdog()
        attempt(port: preferredPort) { [weak self] started in
            guard let self else { return }
            if started {
                completion(.success(self.port))
                return
            }
            self.attempt(port: 0) { startedAgain in
                if startedAgain {
                    completion(.success(self.port))
                } else {
                    completion(.failure(self.lastError ?? URLError(.cannotConnectToHost)))
                }
            }
        }
    }

    func stop() {
        http?.stop()
        http = nil
        watchdog?.cancel()
        watchdog = nil
    }

    func resolveConfirmation(batchID: String, accepted: Bool) {
        lock.lock()
        guard var batch = batches[batchID] else {
            lock.unlock()
            return
        }
        batch.accepted = accepted
        batch.touched = Date()
        batches[batchID] = batch
        lock.unlock()
        onConfirmationResolved?(batchID)
    }

    private func attempt(port: UInt16, completion: @escaping (Bool) -> Void) {
        var settled = false
        func settle(_ value: Bool) {
            guard !settled else { return }
            settled = true
            completion(value)
        }
        let server = HTTPServer(port: port) { [weak self] request in
            self?.route(request) ?? .failure("server stopped", status: 500)
        }
        server.onReady = { [weak self] actual in
            guard let self else { return }
            self.port = actual
            settle(true)
        }
        server.onFailure = { [weak self] error in
            self?.lastError = error
            settle(false)
        }
        http = server
        do {
            try server.start()
        } catch {
            lastError = error
            settle(false)
        }
    }

    private func route(_ request: HTTPServer.Request) -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/macdrop/ping"):
            return .json(["device": deviceName, "version": 1, "port": Int(port), "type": PeerBrowser.localType])
        case ("POST", "/macdrop/begin"):
            return begin(request)
        case ("POST", "/macdrop/chunk"):
            return chunk(request)
        case ("POST", "/macdrop/finish"):
            return finish(request)
        case ("POST", "/macdrop/abort"):
            return abort(request)
        case ("POST", "/macdrop/quit"):
            return .failure("仅桌面端支持", status: 403)
        default:
            return .failure("未知接口", status: 404)
        }
    }

    private func begin(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard let id = request.query["id"], let name = request.query["name"],
              let sizeText = request.query["size"], let size = Int64(sizeText) else {
            return .failure("缺少参数")
        }
        guard size >= 0 else { return .failure("文件大小无效") }
        lock.lock()
        if staging[id] != nil {
            lock.unlock()
            return .json(["ok": true])
        }
        lock.unlock()

        let batchID = request.query["batch"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        let meta = Meta(name: name, path: request.query["path"] ?? "", root: request.query["root"] ?? "", total: size)
        let item = Begin(id: id, meta: meta, batchID: batchID)
        let confirmation = ReceiveConfirmation(
            batchID: batchID,
            senderName: request.query["from"].flatMap { $0.isEmpty ? nil : $0 } ?? "局域网设备",
            fileCount: min(10_000, max(1, Int(request.query["files"] ?? "") ?? 1)),
            totalBytes: max(0, Int64(request.query["bytes"] ?? "") ?? size),
            firstName: name
        )

        var response: HTTPServer.Response
        var confirm: ReceiveConfirmation?
        var started: ReceiveProgress?
        lock.lock()
        if let batch = batches[batchID], batch.accepted == false {
            response = .failure("对方已拒绝接收", status: 403)
        } else if batches[batchID] == nil {
            if pending.count >= Self.maxSessions {
                response = .failure("等待确认的传输过多", status: 429)
            } else {
                batches[batchID] = Batch(confirmation: confirmation, accepted: nil, touched: Date(), created: Date())
                pending[id] = item
                confirm = confirmation
                response = Self.pendingResponse()
            }
        } else if batches[batchID]?.accepted == nil {
            // 发送端每 0.5 秒轮询一次；刷新时间戳，用户还在看弹窗时请求不会被作废
            batches[batchID]?.touched = Date()
            pending[id] = item
            response = Self.pendingResponse()
        } else {
            response = createSessionLocked(item)
            if response.status == 200 { started = ReceiveProgress(id: id, name: name, received: 0, total: size) }
        }
        lock.unlock()
        if let confirm { onConfirm?(confirm) }
        if let started { onProgress?(started) }
        return response
    }

    private func createSessionLocked(_ begin: Begin) -> HTTPServer.Response {
        guard staging.count < Self.maxSessions else { return .failure("同时接收的文件过多", status: 429) }
        let values = try? store.stagingDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        if let available = values?.volumeAvailableCapacity, begin.meta.total > Int64(available) {
            return .failure("接收设备剩余空间不足", status: 507)
        }
        do {
            let url = try store.allocateStaging(transferID: begin.id, fileName: begin.meta.name)
            staging[begin.id] = Entry(url: url, meta: begin.meta)
            pending.removeValue(forKey: begin.id)
            MobileLog.write("开始接收 \(begin.meta.name)（\(begin.meta.total) 字节）")
            return .json(["ok": true])
        } catch {
            return .failure(error.localizedDescription, status: 500)
        }
    }

    private func chunk(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard let id = request.query["id"], let offsetText = request.query["offset"], let offset = Int64(offsetText) else {
            return .failure("缺少参数")
        }
        lock.lock()
        let entry = staging[id]
        lock.unlock()
        guard let entry else { return .failure("未知传输 ID", status: 404) }
        entry.lock.lock()
        defer { entry.lock.unlock() }
        guard offset >= 0, offset % Int64(Self.chunkSize) == 0, offset < entry.meta.total else {
            MobileLog.write("chunk 越界 id=\(id.prefix(8)) offset=\(offset) total=\(entry.meta.total)")
            return .failure("分块偏移越界")
        }
        let expected = min(Int64(Self.chunkSize), entry.meta.total - offset)
        guard Int64(request.body.count) == expected else {
            MobileLog.write("chunk 长度不符 id=\(id.prefix(8)) got=\(request.body.count) want=\(expected)")
            return .failure("分块大小不符")
        }
        do {
            let handle = try FileHandle(forWritingTo: entry.url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: request.body)
            if entry.offsets.insert(offset).inserted { entry.receivedBytes += Int64(request.body.count) }
            entry.lastActivity = Date()
            let percent = Int(entry.receivedBytes * 100 / entry.meta.total)
            if percent != entry.lastPercent {
                entry.lastPercent = percent
                onProgress?(ReceiveProgress(id: id, name: entry.meta.name, received: entry.receivedBytes, total: entry.meta.total))
            }
            return .json(["ok": true])
        } catch {
            return .failure(error.localizedDescription, status: 500)
        }
    }

    private func finish(_ request: HTTPServer.Request) -> HTTPServer.Response {
        guard let id = request.query["id"] else { return .failure("缺少参数") }
        lock.lock()
        let entry = staging.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return .failure("未知传输 ID", status: 404) }
        entry.lock.lock()
        let complete = entry.receivedBytes == entry.meta.total
        entry.lock.unlock()
        guard complete else {
            store.discardStaging(entry.url)
            onStopped?(ReceiveStopped(id: id, name: entry.meta.name, reason: "文件不完整"))
            return .failure("文件不完整：已收 \(entry.receivedBytes) / \(entry.meta.total) 字节", status: 500)
        }
        do {
            let destination = try store.finalize(staging: entry.url, fileName: entry.meta.name,
                                                 relativePath: entry.meta.path, rootName: entry.meta.root,
                                                 expectedSize: entry.meta.total)
            MobileLog.write("接收完成 → \(destination.path)")
            onFinished?(id, destination)
            return .json(["ok": true, "path": destination.path])
        } catch {
            MobileLog.write("接收失败：\(error.localizedDescription)")
            onStopped?(ReceiveStopped(id: id, name: entry.meta.name, reason: error.localizedDescription))
            return .failure(error.localizedDescription, status: 500)
        }
    }

    private func abort(_ request: HTTPServer.Request) -> HTTPServer.Response {
        if let id = request.query["id"] {
            lock.lock()
            let entry = staging.removeValue(forKey: id)
            lock.unlock()
            if let entry {
                store.discardStaging(entry.url)
                onStopped?(ReceiveStopped(id: id, name: entry.meta.name, reason: "发送方已取消"))
            }
        }
        return .json(["ok": true])
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.macdrop.mobile.receive.watchdog"))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.sweep() }
        timer.resume()
        watchdog = timer
    }

    private func sweep() {
        let now = Date()
        var stopped: [ReceiveStopped] = []
        lock.lock()
        for (id, entry) in staging where now.timeIntervalSince(entry.lastActivity) > Self.receiveIdleTimeout {
            staging.removeValue(forKey: id)
            store.discardStaging(entry.url)
            stopped.append(ReceiveStopped(id: id, name: entry.meta.name, reason: "接收超时"))
        }
        var expired: Set<String> = []
        for (id, item) in pending {
            guard let batch = batches[item.batchID],
                  now.timeIntervalSince(batch.touched) > Self.confirmIdleTimeout
                    || now.timeIntervalSince(batch.created) > Self.confirmHardLimit else { continue }
            pending.removeValue(forKey: id)
            batches[item.batchID]?.accepted = false
            expired.insert(item.batchID)
        }
        batches = batches.filter { _, batch in
            batch.accepted == nil || now.timeIntervalSince(batch.created) < Self.batchRetention
        }
        lock.unlock()
        stopped.forEach { onStopped?($0) }
        expired.forEach { onConfirmationResolved?($0) }
    }

    private static func pendingResponse() -> HTTPServer.Response {
        HTTPServer.Response(status: 202, headers: ["Content-Type": "application/json"], body: Data("{\"confirmation\":true}".utf8))
    }

    private static let chunkSize = 2 * 1024 * 1024
    private static let maxSessions = 8
    private static let receiveIdleTimeout: TimeInterval = 20
    /// 发送端停止轮询这么久，就认为对方已放弃，关掉弹窗
    private static let confirmIdleTimeout: TimeInterval = 20
    /// 兜底上限：发送端一直轮询但没人处理，也不能无限挂着
    private static let confirmHardLimit: TimeInterval = 600
    private static let batchRetention: TimeInterval = 600
}
