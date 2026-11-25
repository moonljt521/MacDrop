import Foundation

final class TransferClient {
    private static let chunkSize = 2 * 1024 * 1024
    private static let confirmTimeout: TimeInterval = 300
    private static let parallelChunks = 3
    private let taskLock = NSLock()
    private var activeTask: Task<Void, Never>?

    private struct Session {
        let file: OutgoingFile
        let transferID: String
        let base: String
    }

    private struct ChunkWork {
        let sessionIndex: Int
        let offset: Int64
    }

    private struct ConfirmationRejected: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 一次 begin 的结果
    private enum BeginState {
        case accepted   // 200：会话已建立
        case pending    // 202：等对方确认
        case busy       // 429：对方同时在收的文件太多，稍后重试
    }

    /// 一次建立多少个接收会话。
    ///
    /// 接收端同时在收的文件数有上限（8，见 TransferServer 的 maxSessions），
    /// 一次把几十个文件的会话全建起来会撞上上限，被拒后整个传输失败。
    /// 改成「建一批 → 传完这批（finish 会让接收端释放会话）→ 再建下一批」，
    /// 任意数量的文件都能发，而且不用改协议、对旧版本接收端同样有效。
    private static let sessionWaveSize = 4

    /// 对方忙时的重试间隔
    private static let busyRetryInterval: UInt64 = 300_000_000
    /// 对方忙时最多重试多久（对方传完一个文件就会释放一个会话）
    private static let busyRetryTimeout: TimeInterval = 30

    func send(files: [OutgoingFile],
              to peer: Peer,
              senderName: String,
              progress: @escaping (_ sent: Int64, _ total: Int64, _ currentFile: String) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {
        guard !files.isEmpty else {
            completion(.success(()))
            return
        }
        let task = Task {
            do {
                try await runTransfer(files: files, to: peer, senderName: senderName, progress: progress)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
        taskLock.lock()
        activeTask = task
        taskLock.unlock()
    }

    func cancel() {
        taskLock.lock()
        activeTask?.cancel()
        taskLock.unlock()
    }

    private func runTransfer(files: [OutgoingFile],
                             to peer: Peer,
                             senderName: String,
                             progress: @escaping (Int64, Int64, String) -> Void) async throws {
        let bases = ([peer.host] + peer.alternatives).map { "http://\(Self.formatHost($0)):\(peer.port)" }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        let batchID = UUID().uuidString
        let tracker = ProgressTracker()
        progress(0, total, files[0].url.lastPathComponent)
        // 已建立的所有会话；中途失败时统一 abort，不给接收端留下占位的会话
        var sessions: [Session] = []

        do {
            // 分批建会话：每批先 begin，再把这批文件传完，
            // 接收端 finish 之后就会释放这批的会话槽位
            var index = 0
            while index < files.count {
                try Task.checkCancellation()
                let end = min(index + Self.sessionWaveSize, files.count)
                var waveSessions: [Session] = []
                for file in files[index..<end] {
                    try Task.checkCancellation()
                    let transferID = UUID().uuidString
                    let rootName = file.relativePath.contains("/")
                        ? String(file.relativePath.split(separator: "/").first ?? "") : nil
                    let base = try await Self.announce(
                        bases: bases, transferID: transferID, file: file, rootName: rootName,
                        batchID: batchID, senderName: senderName, fileCount: files.count, batchBytes: total
                    )
                    let session = Session(file: file, transferID: transferID, base: base)
                    sessions.append(session)
                    waveSessions.append(session)
                }
                try await Self.transfer(sessions: waveSessions, tracker: tracker,
                                        total: total, progress: progress)
                index = end
            }
        } catch {
            for session in sessions { Self.abort(baseURL: session.base, transferID: session.transferID) }
            throw error
        }
    }

    /// 传一批文件：分块并发，每块确认后才继续
    private static func transfer(sessions: [Session],
                                 tracker: ProgressTracker,
                                 total: Int64,
                                 progress: @escaping (Int64, Int64, String) -> Void) async throws {
        var works: [ChunkWork] = []
        for (index, session) in sessions.enumerated() {
            let count = Self.chunkCount(session.file.size)
            var offset: Int64 = 0
            for _ in 0..<count {
                works.append(ChunkWork(sessionIndex: index, offset: offset))
                offset += Int64(Self.chunkSize)
            }
        }
        for session in sessions where session.file.size == 0 {
            try await Self.postFinish(baseURL: session.base, transferID: session.transferID)
        }

        let queue = ChunkQueue(works)
        let remaining = RemainingCounter(sessions.map { Self.chunkCount($0.file.size) })
        let workerCount = min(Self.parallelChunks, max(1, works.count))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    while !Task.isCancelled, let work = queue.next() {
                        try Task.checkCancellation()
                        let session = sessions[work.sessionIndex]
                        let data = try Self.readChunk(at: session.file.url, offset: work.offset, length: Int64(Self.chunkSize))
                        try await Self.postChunk(baseURL: session.base, transferID: session.transferID, offset: work.offset, data: data)
                        let snapshot = tracker.add(Int64(data.count), file: session.file.url.lastPathComponent)
                        progress(snapshot.sent, total, snapshot.current)
                        if remaining.finishOne(work.sessionIndex) {
                            try await Self.postFinish(baseURL: session.base, transferID: session.transferID)
                        }
                    }
                    if Task.isCancelled { throw CancellationError() }
                }
            }
            try await group.waitForAll()
        }
    }

    private static func formatHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    private static func chunkCount(_ size: Int64) -> Int {
        Int((size + Int64(chunkSize) - 1) / Int64(chunkSize))
    }

    private static func readChunk(at url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(length)), !data.isEmpty else {
            throw NSError(domain: "MoonDropMobile", code: 500, userInfo: [NSLocalizedDescriptionKey: moonT("读取文件时提前结束")])
        }
        return data
    }

    private static func announce(bases: [String], transferID: String, file: OutgoingFile, rootName: String?,
                                 batchID: String, senderName: String, fileCount: Int, batchBytes: Int64) async throws -> String {
        var lastError: Error = URLError(.badURL)
        var firstError: Error?
        // 对方忙（同时在收的文件太多）时的等待上限
        let busyDeadline = Date().addingTimeInterval(Self.busyRetryTimeout)

        for round in 0..<2 {
            var baseIndex = 0
            while baseIndex < bases.count {
                let base = bases[baseIndex]
                try Task.checkCancellation()
                do {
                    let state = try await announceOnce(baseURL: base, transferID: transferID, file: file,
                                                       rootName: rootName, batchID: batchID, senderName: senderName,
                                                       fileCount: fileCount, batchBytes: batchBytes)
                    switch state {
                    case .accepted:
                        return base
                    case .pending:
                        return try await awaitAcceptance(baseURL: base, transferID: transferID, file: file,
                                                         rootName: rootName, batchID: batchID, senderName: senderName,
                                                         fileCount: fileCount, batchBytes: batchBytes)
                    case .busy:
                        // 对方同时在收的文件太多：等它传完一个文件腾出槽位再重试。
                        // 本批只建了 4 个会话（远小于对方上限 8），
                        // 所以等的一定是对方其它传输释放出来的槽位，不会自己把自己堵死。
                        guard Date() < busyDeadline else {
                            throw NSError(domain: "MoonDropMobile", code: 429, userInfo: [
                                NSLocalizedDescriptionKey: moonT("对方正在接收其它文件，请稍后重试")
                            ])
                        }
                        try await Task.sleep(nanoseconds: Self.busyRetryInterval)
                        continue
                    }
                } catch let error as ConfirmationRejected {
                    throw error
                } catch {
                    if error is CancellationError { throw error }
                    if firstError == nil { firstError = error }
                    lastError = error
                    // 这个地址连不上，换下一个
                    baseIndex += 1
                }
            }
            if round == 0 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
        let reason = (firstError ?? lastError).localizedDescription
        throw NSError(domain: "MoonDropMobile", code: 1, userInfo: [
            NSLocalizedDescriptionKey: moonTF("%@（对方可能在后台或已离线，请在对方屏幕上打开 MoonDrop）", reason)
        ])
    }

    private static func awaitAcceptance(baseURL: String, transferID: String, file: OutgoingFile, rootName: String?,
                                        batchID: String, senderName: String, fileCount: Int, batchBytes: Int64) async throws -> String {
        let deadline = Date().addingTimeInterval(confirmTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let state = try await announceOnce(baseURL: baseURL, transferID: transferID, file: file,
                                                rootName: rootName, batchID: batchID, senderName: senderName,
                                                fileCount: fileCount, batchBytes: batchBytes)
            switch state {
            case .accepted:
                return baseURL
            case .pending, .busy:
                // 还在等确认（或者对方正忙），继续轮询
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        throw NSError(domain: "MoonDropMobile", code: 408, userInfo: [NSLocalizedDescriptionKey: moonT("等待对方确认接收超时")])
    }

    private static func announceOnce(baseURL: String, transferID: String, file: OutgoingFile, rootName: String?,
                                     batchID: String, senderName: String, fileCount: Int, batchBytes: Int64) async throws -> BeginState {
        var components = URLComponents(string: "\(baseURL)/macdrop/begin")
        components?.queryItems = [
            URLQueryItem(name: "id", value: transferID),
            URLQueryItem(name: "name", value: file.url.lastPathComponent),
            URLQueryItem(name: "path", value: file.relativePath),
            URLQueryItem(name: "size", value: String(file.size)),
            URLQueryItem(name: "root", value: rootName ?? ""),
            URLQueryItem(name: "batch", value: batchID),
            URLQueryItem(name: "from", value: senderName),
            URLQueryItem(name: "files", value: String(fileCount)),
            URLQueryItem(name: "bytes", value: String(batchBytes))
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        if code == 200 { return .accepted }
        if code == 202 { return .pending }
        if code == 429 {
            // 对方同时在收的文件太多：等它传完一个文件腾出槽位
            return .busy
        }
        if code == 403 {
            let message = String(data: data, encoding: .utf8) ?? moonT("对方已拒绝接收")
            throw ConfirmationRejected(message: message)
        }
        throw URLError(.badServerResponse)
    }

    private static func postChunk(baseURL: String, transferID: String, offset: Int64, data: Data) async throws {
        var lastError: Error = URLError(.badServerResponse)
        for attempt in 0..<3 {
            do {
                try await postChunkOnce(baseURL: baseURL, transferID: transferID, offset: offset, data: data)
                return
            } catch {
                lastError = error
                guard attempt < 2, !Task.isCancelled else { break }
                try await Task.sleep(nanoseconds: UInt64(400_000_000) * UInt64(attempt + 1))
            }
        }
        throw lastError
    }

    private static func postChunkOnce(baseURL: String, transferID: String, offset: Int64, data: Data) async throws {
        guard let url = URL(string: "\(baseURL)/macdrop/chunk?id=\(transferID)&offset=\(offset)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw URLError(.badServerResponse)
        }
    }

    private static func postFinish(baseURL: String, transferID: String) async throws {
        guard let url = URL(string: "\(baseURL)/macdrop/finish?id=\(transferID)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
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

    private final class RemainingCounter {
        private let lock = NSLock()
        private var counts: [Int]
        init(_ counts: [Int]) { self.counts = counts }
        func finishOne(_ index: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard index < counts.count, counts[index] > 0 else { return false }
            counts[index] -= 1
            return counts[index] == 0
        }
    }
}
