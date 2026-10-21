import Foundation

/// 手机端接收服务：HTTP 接口与 macOS 端完全兼容。
final class TransferServer {

    private struct Meta {
        var name: String
        var path: String
        var root: String
        var total: Int64
    }

    private let store: FileStore
    private let deviceName: String
    private var http: HTTPServer?
    private var staging: [String: (url: URL, meta: Meta)] = [:]
    private let lock = NSLock()
    private var lastPercent = -1
    private var lastError: Error?

    private(set) var port: UInt16 = 0

    var onProgress: ((Double, String) -> Void)?
    var onFinished: ((URL) -> Void)?

    init(deviceName: String, store: FileStore) {
        self.deviceName = deviceName
        self.store = store
    }

    /// 优先监听 52345；被占用时退回系统随机端口。
    func start(preferredPort: UInt16 = 52345,
               completion: @escaping (Result<UInt16, Error>) -> Void) {
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

    // MARK: - 路由

    private func route(_ request: HTTPServer.Request) -> HTTPServer.Response {
        switch (request.method, request.path) {

        case ("GET", "/macdrop/ping"):
            return .json(["device": deviceName, "version": 1, "port": Int(port)])

        case ("POST", "/macdrop/begin"):
            guard let id = request.query["id"],
                  let name = request.query["name"],
                  let sizeText = request.query["size"],
                  let size = Int64(sizeText) else {
                return .failure("缺少参数")
            }
            do {
                let url = try store.allocateStaging(transferID: id, fileName: name)
                lock.lock()
                staging[id] = (url, Meta(name: name,
                                         path: request.query["path"] ?? "",
                                         root: request.query["root"] ?? "",
                                         total: size))
                lastPercent = -1
                lock.unlock()
                MobileLog.write("开始接收 \(name)（\(size) 字节）")
                onProgress?(0, name)
                return .json(["ok": true])
            } catch {
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/chunk"):
            guard let id = request.query["id"],
                  let offsetText = request.query["offset"],
                  let offset = Int64(offsetText) else {
                return .failure("缺少参数")
            }
            lock.lock()
            let entry = staging[id]
            lock.unlock()
            guard let entry else {
                return .failure("未知传输 ID", status: 404)
            }
            do {
                let handle = try FileHandle(forWritingTo: entry.url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: request.body)

                let received = offset + Int64(request.body.count)
                let percent = entry.meta.total > 0
                    ? Int(min(100, received * 100 / entry.meta.total))
                    : 0
                lock.lock()
                let changed = percent != lastPercent
                if changed { lastPercent = percent }
                lock.unlock()
                if changed {
                    onProgress?(Double(percent) / 100, entry.meta.name)
                }
                return .json(["ok": true])
            } catch {
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/finish"):
            guard let id = request.query["id"] else { return .failure("缺少参数") }
            lock.lock()
            let entry = staging.removeValue(forKey: id)
            lock.unlock()
            guard let entry else {
                return .failure("未知传输 ID", status: 404)
            }
            do {
                let destination = try store.finalize(staging: entry.url,
                                                     fileName: entry.meta.name,
                                                     relativePath: entry.meta.path,
                                                     rootName: entry.meta.root,
                                                     expectedSize: entry.meta.total)
                MobileLog.write("接收完成 → \(destination.path)")
                onFinished?(destination)
                return .json(["ok": true, "path": destination.path])
            } catch {
                MobileLog.write("接收失败：\(error.localizedDescription)")
                return .failure(error.localizedDescription, status: 500)
            }

        case ("POST", "/macdrop/abort"):
            if let id = request.query["id"] {
                lock.lock()
                let entry = staging.removeValue(forKey: id)
                lock.unlock()
                if let entry { store.discardStaging(entry.url) }
            }
            return .json(["ok": true])

        case ("POST", "/macdrop/quit"):
            return .failure("仅桌面端支持", status: 403)

        default:
            return .failure("未知接口", status: 404)
        }
    }
}
