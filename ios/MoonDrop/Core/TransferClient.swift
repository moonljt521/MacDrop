import Foundation

/// 发送端：announce → 分块并发上传 → finish。
/// 分块自带偏移，接收端按偏移随机写，所以同一文件的块可以乱序到达。
final class TransferClient {

    private static let chunkSize = 2 * 1024 * 1024
    /// 同时在途的连接数
    private let parallelChunks = 3

    private struct Session {
        let file: OutgoingFile
        let transferID: String
        /// 实际连通的地址（首选地址失败时可能是备选地址）
        let base: String
    }

    private struct ChunkWork {
        let sessionIndex: Int
        let offset: Int64
    }

    func send(files: [OutgoingFile],
              to peer: Peer,
              progress: @escaping (_ sent: Int64, _ total: Int64, _ currentFile: String) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {

        guard !files.isEmpty else {
            completion(.success(()))
            return
        }

        Task {
            do {
                try await runTransfer(files: files, to: peer, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func runTransfer(files: [OutgoingFile],
                             to peer: Peer,
                             progress: @escaping (Int64, Int64, String) -> Void) async throws {
        // 首选地址（局域网 IP）连不通时，依次尝试同一台设备的其它地址
        let bases = ([peer.host] + peer.alternatives).map { "http://\($0):\(peer.port)" }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let tracker = ProgressTracker()
        progress(0, total, files[0].url.lastPathComponent)

        // 1) 为每个文件建会话
        var sessions: [Session] = []
        for file in files {
            let transferID = UUID().uuidString
            let rootName = file.relativePath.contains("/")
                ? String(file.relativePath.split(separator: "/").first ?? "")
                : nil
            let base: String
            do {
                base = try await Self.announce(bases: bases, transferID: transferID,
                                               file: file, rootName: rootName)
            } catch {
                for session in sessions { Self.abort(baseURL: session.base, transferID: session.transferID) }
                throw error
            }
            sessions.append(Session(file: file, transferID: transferID, base: base))
        }
        let sessionList = sessions

        // 2) 构造全局分块队列
        var works: [ChunkWork] = []
        for (index, session) in sessionList.enumerated() {
            let count = Self.chunkCount(session.file.size)
            var offset: Int64 = 0
            for _ in 0..<count {
                works.append(ChunkWork(sessionIndex: index, offset: offset))
                offset += Int64(Self.chunkSize)
            }
        }

        // 空文件没有分块，直接收尾
        for session in sessionList where session.file.size == 0 {
            try await Self.postFinish(baseURL: session.base, transferID: session.transferID)
        }

        // 3) 并发发送
        let queue = ChunkQueue(works)
        let remaining = RemainingCounter(sessionList.map { Self.chunkCount($0.file.size) })
        let chunkSize = Self.chunkSize
        let workerCount = min(parallelChunks, max(1, works.count))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<workerCount {
                    group.addTask {
                        while let work = queue.next() {
                            let session = sessionList[work.sessionIndex]
                            let data = try Self.readChunk(at: session.file.url,
                                                         offset: work.offset,
                                                         length: Int64(chunkSize))
                            try await Self.postChunk(baseURL: session.base, transferID: session.transferID,
                                                    offset: work.offset, data: data)
                            let snapshot = tracker.add(Int64(data.count),
                                                      file: session.file.url.lastPathComponent)
                            progress(snapshot.sent, total, snapshot.current)
                            if remaining.finishOne(work.sessionIndex) {
                                try await Self.postFinish(baseURL: session.base, transferID: session.transferID)
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch {
            for session in sessionList { Self.abort(baseURL: session.base, transferID: session.transferID) }
            throw error
        }
    }

    // MARK: - HTTP 辅助

    private static func chunkCount(_ size: Int64) -> Int {
        Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    /// 读取文件的某一段（每个并发任务各开一个句柄，按偏移定位）
    private static func readChunk(at url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), !data.isEmpty else {
            throw NSError(domain: "MoonDropMobile", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "读取文件时提前结束"
            ])
        }
        return data
    }

    /// 依次尝试各地址；全部失败再整体重试一轮
    /// （对端刚被唤醒时，第一次连接常被直接丢弃）
    private static func announce(bases: [String],
                                 transferID: String,
                                 file: OutgoingFile,
                                 rootName: String?) async throws -> String {
        var lastError: Error = URLError(.badURL)
        for round in 0..<2 {
            for base in bases {
                do {
                    try await announceOnce(baseURL: base, transferID: transferID,
                                           file: file, rootName: rootName)
                    return base
                } catch {
                    lastError = error
                }
            }
            if round == 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        let reason = lastError.localizedDescription
        throw NSError(domain: "MoonDropMobile", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(reason)（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）"
        ])
    }

    private static func announceOnce(baseURL: String,
                                     transferID: String,
                                     file: OutgoingFile,
                                     rootName: String?) async throws {
        var components = URLComponents(string: "\(baseURL)/macdrop/begin")
        components?.queryItems = [
            URLQueryItem(name: "id", value: transferID),
            URLQueryItem(name: "name", value: file.url.lastPathComponent),
            URLQueryItem(name: "path", value: file.relativePath),
            URLQueryItem(name: "size", value: String(file.size)),
            URLQueryItem(name: "root", value: rootName ?? "")
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 对端 App 挂起时不会回包，短超时才能快速失败并换地址/重试
        request.timeoutInterval = 4
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func postChunk(baseURL: String,
                                  transferID: String,
                                  offset: Int64,
                                  data: Data) async throws {
        guard let url = URL(string: "\(baseURL)/macdrop/chunk?id=\(transferID)&offset=\(offset)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func postFinish(baseURL: String, transferID: String) async throws {
        guard let url = URL(string: "\(baseURL)/macdrop/finish?id=\(transferID)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode,
              (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func abort(baseURL: String, transferID: String) {
        guard let url = URL(string: "\(baseURL)/macdrop/abort?id=\(transferID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - 并发辅助

    /// 线程安全的累计进度
    private final class ProgressTracker {
        private let lock = NSLock()
        private var sent: Int64 = 0
        private var current: String = ""

        func add(_ bytes: Int64, file: String) -> (sent: Int64, current: String) {
            lock.lock()
            defer { lock.unlock() }
            sent += bytes
            current = file
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
}
