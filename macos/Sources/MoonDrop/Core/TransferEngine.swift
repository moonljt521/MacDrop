import Foundation

/// 单个待传输的文件
struct FileItem: Identifiable {
    let id = UUID()
    var url: URL
    var relativePath: String
    var size: Int64

    var isDirectory: Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}

struct TransferProgress {
    var sentBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var currentFile: String = ""

    var fraction: Double {
        totalBytes > 0 ? Double(sentBytes) / Double(totalBytes) : 0
    }
}

/// 负责：接收端落盘 + 发送端推送。
final class TransferEngine {

    static let shared = TransferEngine()

    private let chunkSize = 2 * 1024 * 1024
    private let fm = FileManager.default
    private let lock = NSLock()
    private var staging: [String: URL] = [:]   // transferID -> 临时文件

    // MARK: - 接收端

    /// 开始一次接收，创建临时文件
    func beginReceive(transferID: String, fileName: String, total: Int64) throws {
        let dir = stagingDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 传输 ID 做随机前缀，避免并发同名冲突
        let safe = sanitize(fileName)
        let tmp = dir.appendingPathComponent("\(transferID)__\(safe)")
        if fm.fileExists(atPath: tmp.path) {
            try fm.removeItem(at: tmp)
        }
        fm.createFile(atPath: tmp.path, contents: nil)
        lock.lock(); staging[transferID] = tmp; lock.unlock()
    }

    /// 写入一个分块
    func appendChunk(transferID: String, offset: Int64, data: Data) throws {
        lock.lock()
        let url = staging[transferID]
        lock.unlock()
        guard let url else { throw NSError(domain: "MoonDrop", code: 404,
                                            userInfo: [NSLocalizedDescriptionKey: "未知传输 ID"]) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        try fh.write(contentsOf: data)
    }

    /// 完成并原子移动到目标目录。返回最终路径。
    /// expectedSize 不为空时先校验落盘字节数，不完整就报错并删掉半截文件。
    @discardableResult
    func finishReceive(transferID: String, fileName: String, relativePath: String?,
                       rootName: String?, expectedSize: Int64? = nil) throws -> URL {
        lock.lock()
        let tmp = staging.removeValue(forKey: transferID)
        lock.unlock()
        guard let tmp else {
            throw NSError(domain: "MoonDrop", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "未知传输 ID"])
        }

        if let expectedSize {
            let attrs = try? fm.attributesOfItem(atPath: tmp.path)
            let got = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            guard got == expectedSize else {
                try? fm.removeItem(at: tmp)
                throw NSError(domain: "MoonDrop", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "文件不完整：已收 \(got) / \(expectedSize) 字节"
                ])
            }
        }

        let base = Config.shared.downloadURL
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        // 目录拖放：按相对路径还原目录结构；老发送端只带 root 时退回顶层目录
        var targetDir = base
        for component in relativeDirectories(path: relativePath, root: rootName) {
            targetDir.appendPathComponent(component, isDirectory: true)
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let dest = uniqueURL(in: targetDir, name: sanitize(fileName))
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }

    func cancelReceive(transferID: String) {
        lock.lock()
        let url = staging.removeValue(forKey: transferID)
        lock.unlock()
        if let url { try? fm.removeItem(at: url) }
    }

    // MARK: - 发送端

    /// 把一批文件推送到对端：先为每个文件建会话，再分块并发发送。
    /// 分块自带偏移，接收端按偏移随机写，所以同一文件的块可以乱序到达。
    func send(items: [FileItem],
              to peer: Peer,
              progress: @escaping (TransferProgress) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {

        // 首选地址（局域网 IP）连不通时，依次尝试同一台设备的其它地址
        let bases = ([peer.host] + peer.alternatives).map { "http://\($0):\(peer.port)" }
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let tracker = SendProgressTracker()

        var initial = TransferProgress()
        initial.totalBytes = total
        progress(initial)

        func report(bytes: Int64, file: String) {
            tracker.add(bytes, file: file)
            DispatchQueue.main.async {
                // 读当前累计值而不是回调里的快照：
                // 并发时两个分块的回调可能乱序进主队列，用旧快照会让进度条回退
                let snapshot = tracker.snapshot()
                var state = TransferProgress()
                state.totalBytes = total
                state.sentBytes = snapshot.sent
                state.currentFile = snapshot.current
                progress(state)
            }
        }

        var sessions: [SendSession] = []

        func announceNext(_ index: Int) {
            guard index < items.count else {
                runParallelSend(sessions: sessions, report: report, completion: completion)
                return
            }
            let item = items[index]
            let transferID = UUID().uuidString
            // 目录拖放：把最外层目录名告诉接收端，让它保持目录结构
            let rootName = item.relativePath.contains("/")
                ? String(item.relativePath.split(separator: "/").first ?? "")
                : nil

            announce(bases: bases, transferID: transferID, fileName: item.url.lastPathComponent,
                     relPath: item.relativePath, total: item.size, rootName: rootName) { result in
                switch result {
                case .failure(let error):
                    NSLog("[MoonDrop] 发送失败 \(item.url.lastPathComponent): \(error)")
                    for session in sessions { TransferEngine.abort(transferID: session.transferID, baseURL: session.base) }
                    completion(.failure(error))
                case .success(let base):
                    sessions.append(SendSession(item: item, transferID: transferID, base: base))
                    announceNext(index + 1)
                }
            }
        }
        announceNext(0)
    }

    /// 并发发送所有分块；某个文件的最后一块发完后再给它发 finish。
    private func runParallelSend(sessions: [SendSession],
                                 report: @escaping (Int64, String) -> Void,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        guard !sessions.isEmpty else {
            completion(.success(()))
            return
        }

        var works: [ChunkWork] = []
        var perFile: [Int] = []
        for (index, session) in sessions.enumerated() {
            let count = Int((session.item.size + Int64(chunkSize) - 1) / Int64(chunkSize))
            perFile.append(count)
            var offset: Int64 = 0
            for _ in 0..<count {
                works.append(ChunkWork(sessionIndex: index, offset: offset))
                offset += Int64(chunkSize)
            }
        }

        // 空文件没有分块，直接收尾
        for (index, session) in sessions.enumerated() where perFile[index] == 0 {
            do {
                try TransferEngine.postFinish(baseURL: session.base, transferID: session.transferID)
            } catch {
                completion(.failure(error))
                return
            }
        }

        let queue = ChunkQueue(works)
        let remaining = RemainingCounter(perFile)
        let failure = FailureBox()
        let group = DispatchGroup()
        let workers = DispatchQueue(label: "com.macdrop.send.workers", attributes: .concurrent)
        let workerCount = min(Config.parallelChunks, max(1, works.count))

        for _ in 0..<workerCount {
            workers.async(group: group) {
                while true {
                    if failure.hasValue { return }
                    guard let work = queue.next() else { return }
                    let session = sessions[work.sessionIndex]
                    do {
                        let data = try TransferEngine.readChunk(at: session.item.url,
                                                             offset: work.offset,
                                                             length: Int64(self.chunkSize))
                        try TransferEngine.postChunk(baseURL: session.base, transferID: session.transferID,
                                                    offset: work.offset, data: data)
                        report(Int64(data.count), session.item.url.lastPathComponent)
                        if remaining.finishOne(work.sessionIndex) {
                            try TransferEngine.postFinish(baseURL: session.base, transferID: session.transferID)
                        }
                    } catch {
                        failure.set(error)
                        return
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if let error = failure.value {
                NSLog("[MoonDrop] 上传中断: \(error)")
                for session in sessions { TransferEngine.abort(transferID: session.transferID, baseURL: session.base) }
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    private struct SendSession {
        let item: FileItem
        let transferID: String
        /// 实际连通的地址（首选地址失败时可能是备选地址）
        let base: String
    }

    private struct ChunkWork {
        let sessionIndex: Int
        let offset: Int64
    }

    /// 线程安全的累计进度
    private final class SendProgressTracker {
        private let lock = NSLock()
        private var sent: Int64 = 0
        private var current: String = ""

        func add(_ bytes: Int64, file: String) {
            lock.lock()
            defer { lock.unlock() }
            sent += bytes
            current = file
        }

        /// 当前累计值（单调递增）
        func snapshot() -> (sent: Int64, current: String) {
            lock.lock()
            defer { lock.unlock() }
            return (sent, current)
        }
    }

    private final class ChunkQueue {
        private let lock = NSLock()
        private let works: [ChunkWork]
        private var index = 0

        init(_ works: [ChunkWork]) { self.works = works }

        func next() -> ChunkWork? {
            lock.lock()
            defer { lock.unlock() }
            guard index < works.count else { return nil }
            let work = works[index]
            index += 1
            return work
        }
    }

    /// 每个文件还剩多少块没发完
    private final class RemainingCounter {
        private let lock = NSLock()
        private var counts: [Int]

        init(_ counts: [Int]) { self.counts = counts }

        /// 返回 true 表示该文件的块已全部发完
        func finishOne(_ index: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard index < counts.count, counts[index] > 0 else { return false }
            counts[index] -= 1
            return counts[index] == 0
        }
    }

    /// 线程安全的错误容器
    private final class ErrorBox {
        private let lock = NSLock()
        private var error: Error?

        func set(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }

        var value: Error? {
            lock.lock()
            defer { lock.unlock() }
            return error
        }
    }

    private final class FailureBox {
        private let lock = NSLock()
        private var error: Error?

        var hasValue: Bool {
            lock.lock(); defer { lock.unlock() }
            return error != nil
        }

        var value: Error? {
            lock.lock(); defer { lock.unlock() }
            return error
        }

        func set(_ error: Error) {
            lock.lock()
            self.error = error
            lock.unlock()
        }
    }

    /// 依次尝试各地址；全部失败再整体重试一轮
    /// （对端刚被唤醒时，第一次连接常被直接丢弃）
    private func announce(bases: [String], transferID: String, fileName: String, relPath: String,
                          total: Int64, rootName: String?,
                          completion: @escaping (Result<String, Error>) -> Void) {
        let lastError = ErrorBox()

        func attempt(_ index: Int, round: Int) {
            guard index < bases.count else {
                if round == 0 {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { attempt(0, round: 1) }
                } else {
                    let reason = (lastError.value ?? URLError(.badURL)).localizedDescription
                    completion(.failure(NSError(domain: "MoonDrop", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(reason)（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）"
                    ])))
                }
                return
            }
            let base = bases[index]
            announceOnce(transferID: transferID, fileName: fileName,
                         relPath: relPath, total: total, rootName: rootName, baseURL: base) { result in
                switch result {
                case .success:
                    completion(.success(base))
                case .failure(let error):
                    lastError.set(error)
                    attempt(index + 1, round: round)
                }
            }
        }
        attempt(0, round: 0)
    }

    private func announceOnce(transferID: String, fileName: String, relPath: String,
                              total: Int64, rootName: String?, baseURL: String,
                              completion: @escaping (Result<Void, Error>) -> Void) {
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "name", value: fileName),
            .init(name: "path", value: relPath),
            .init(name: "size", value: String(total)),
            .init(name: "root", value: rootName ?? "")
        ]
        guard let url = URL(string: "\(baseURL)/macdrop/begin?id=\(transferID)&\(comps.percentEncodedQuery ?? "")") else {
            completion(.failure(URLError(.badURL))); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 对端 App 挂起时不会回包，短超时才能快速失败并换地址/重试
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { return completion(.failure(err)) }
            guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                return completion(.failure(URLError(.badServerResponse)))
            }
            completion(.success(()))
        }.resume()
    }

    /// 读取文件的某一段（每个并发任务各开一个句柄，按偏移定位）
    private static func readChunk(at url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), !data.isEmpty else {
            throw NSError(domain: "MoonDrop", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "读取文件时提前结束"])
        }
        return data
    }

    /// 发送一个分块并等待结果（工作线程里同步调用）
    private static func postChunk(baseURL: String, transferID: String,
                                  offset: Int64, data: Data) throws {
        guard let url = URL(string: "\(baseURL)/macdrop/chunk?id=\(transferID)&offset=\(offset)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        URLSession.shared.uploadTask(with: request, from: data) { _, response, error in
            if let error {
                result = .failure(error)
            } else if let code = (response as? HTTPURLResponse)?.statusCode,
                      !(200..<300).contains(code) {
                result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        try result.get()
    }

    /// 收尾：校验并交付
    private static func postFinish(baseURL: String, transferID: String) throws {
        guard let url = URL(string: "\(baseURL)/macdrop/finish?id=\(transferID)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                result = .failure(error)
            } else if let code = (response as? HTTPURLResponse)?.statusCode,
                      !(200..<300).contains(code) {
                result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        try result.get()
    }

    /// 放弃一个未完成的传输
    private static func abort(transferID: String, baseURL: String) {
        guard let url = URL(string: "\(baseURL)/macdrop/abort?id=\(transferID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - 辅助

    /// 把拖进来的 URL 展开成文件列表，目录递归
    func expand(urls: [URL]) -> [FileItem] {
        var out: [FileItem] = []

        func walk(_ url: URL, prefix: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            let name = url.lastPathComponent
            // 隐藏文件（.DS_Store 等）不参与传输，和移动端保持一致
            guard !name.hasPrefix(".") else { return }
            if isDir.boolValue {
                guard let kids = try? fm.contentsOfDirectory(at: url,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
                for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    walk(kid, prefix: prefix.isEmpty ? kid.lastPathComponent
                                                     : "\(prefix)/\(kid.lastPathComponent)")
                }
            } else {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                out.append(FileItem(url: url, relativePath: prefix, size: size))
            }
        }

        for u in urls {
            walk(u, prefix: u.lastPathComponent)
        }
        return out
    }

    private func stagingDir() -> URL {
        Config.stagingDir
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 path 的目录部分拆成安全的目录名；path 只有文件名时用 root 兜底。
    private func relativeDirectories(path: String?, root: String?) -> [String] {
        let directories = ((path ?? "") as NSString).deletingLastPathComponent
        var components = directories.split(separator: "/")
            .map { sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if components.isEmpty, let root, !root.isEmpty {
            components = [sanitize(root)]
        }
        return components
    }

    /// 同名避让：foo.txt -> foo (1).txt
    private func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 1
        while true {
            let n = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
            if i > 999 { return dir.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)") }
        }
    }
}