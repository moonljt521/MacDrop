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
        guard let url else { throw NSError(domain: "MacDrop", code: 404,
                                            userInfo: [NSLocalizedDescriptionKey: "未知传输 ID"]) }
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        try fh.write(contentsOf: data)
    }

    /// 完成并原子移动到目标目录。返回最终路径。
    /// expectedSize 不为空时先校验落盘字节数，不完整就报错并删掉半截文件。
    @discardableResult
    func finishReceive(transferID: String, fileName: String, rootName: String?,
                       expectedSize: Int64? = nil) throws -> URL {
        lock.lock()
        let tmp = staging.removeValue(forKey: transferID)
        lock.unlock()
        guard let tmp else {
            throw NSError(domain: "MacDrop", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "未知传输 ID"])
        }

        if let expectedSize {
            let attrs = try? fm.attributesOfItem(atPath: tmp.path)
            let got = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
            guard got == expectedSize else {
                try? fm.removeItem(at: tmp)
                throw NSError(domain: "MacDrop", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "文件不完整：已收 \(got) / \(expectedSize) 字节"
                ])
            }
        }

        let base = Config.shared.downloadURL
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        // 若是文件夹拖放，落盘到 <base>/<文件夹名>/
        var targetDir = base
        if let root = rootName, !root.isEmpty {
            targetDir = base.appendingPathComponent(sanitize(root), isDirectory: true)
            try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        }

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

    /// 把一批文件推送到对端。逐个文件 → 逐个分块。
    func send(items: [FileItem],
              to peer: Peer,
              progress: @escaping (TransferProgress) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {

        let base = "http://\(peer.host):\(peer.port)"
        var state = TransferProgress()
        state.totalBytes = items.reduce(0) { $0 + $1.size }
        progress(state)

        // 目录拖放：把最外层目录名告诉接收端，让它保持目录结构
        let rootName = items.count == 1 && items[0].relativePath.contains("/")
            ? String(items[0].relativePath.split(separator: "/").first ?? "")
            : nil

        func next(_ idx: Int) {
            guard idx < items.count else {
                completion(.success(()))
                return
            }
            let item = items[idx]
            state.currentFile = item.url.lastPathComponent
            progress(state)

            sendFile(item, idx: idx, baseURL: base, rootName: rootName,
                     state: state, progress: progress, next: next,
                     completion: completion)
        }
        next(0)
    }

    private func sendFile(_ item: FileItem,
                          idx: Int,
                          baseURL: String,
                          rootName: String?,
                          state: TransferProgress,
                          progress: @escaping (TransferProgress) -> Void,
                          next: @escaping (Int) -> Void,
                          completion: @escaping (Result<Void, Error>) -> Void) {

        let transferID = UUID().uuidString
        let rel = item.relativePath

        // 1) announce
        announce(transferID: transferID, fileName: item.url.lastPathComponent,
                 relPath: rel, total: item.size, rootName: rootName,
                 baseURL: baseURL) { result in
            switch result {
            case .failure(let err):
                // 关键：必须把失败上报，否则界面永远停在「传输中 0%」
                NSLog("[MacDrop] 发送失败 \(item.url.lastPathComponent): \(err)")
                completion(.failure(err))
            case .success:
                self.uploadChunks(item: item, transferID: transferID,
                                  baseURL: baseURL, state: state,
                                  progress: progress) { upResult in
                    switch upResult {
                    case .success:
                        next(idx + 1)
                    case .failure(let err):
                        NSLog("[MacDrop] 上传中断: \(err)")
                        self.abort(transferID: transferID, baseURL: baseURL) { _ in }
                        completion(.failure(err))
                    }
                }
            }
        }
    }

    private func announce(transferID: String, fileName: String, relPath: String,
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
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { return completion(.failure(err)) }
            guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                return completion(.failure(URLError(.badServerResponse)))
            }
            completion(.success(()))
        }.resume()
    }

    private func uploadChunks(item: FileItem, transferID: String, baseURL: String,
                              state: TransferProgress,
                              progress: @escaping (TransferProgress) -> Void,
                              completion: @escaping (Result<Void, Error>) -> Void) {

        guard let fh = try? FileHandle(forReadingFrom: item.url) else {
            completion(.failure(NSError(domain: "MacDrop", code: 500,
                                        userInfo: [NSLocalizedDescriptionKey: "无法读取文件"])))
            return
        }

        var offset: Int64 = 0
        var localState = state

        // 本方法是同步的：分块是异步逐个发出的，句柄必须活到最后一个分块发完。
        // 不能在函数返回时关闭（defer），否则第二块开始读取就会失败。
        func finishAndClose() {
            finish(transferID: transferID, baseURL: baseURL) { result in
                try? fh.close()
                completion(result)
            }
        }

        func failAndClose(_ error: Error) {
            try? fh.close()
            completion(.failure(error))
        }

        func sendNext() {
            guard offset < item.size else {
                finishAndClose()
                return
            }
            let want = Int64(chunkSize)
            guard let data = try? fh.read(upToCount: Int(want)), !data.isEmpty else {
                // 读到一半提前结束说明源文件变了，绝不能当成功收尾（否则对端留下截断文件）
                failAndClose(NSError(domain: "MacDrop", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "读取提前结束（\(offset)/\(item.size) 字节）"
                ]))
                return
            }
            let currentOffset = offset
            offset += Int64(data.count)

            var req = URLRequest(url: URL(string: "\(baseURL)/macdrop/chunk?id=\(transferID)&offset=\(currentOffset)")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

            URLSession.shared.uploadTask(with: req, from: data) { _, resp, err in
                if let err { return failAndClose(err) }
                guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                    return failAndClose(URLError(.badServerResponse))
                }
                localState.sentBytes += Int64(data.count)
                DispatchQueue.main.async { progress(localState) }
                sendNext()
            }.resume()
        }
        sendNext()
    }

    private func finish(transferID: String, baseURL: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "\(baseURL)/macdrop/finish?id=\(transferID)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { return completion(.failure(err)) }
            guard let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
                return completion(.failure(URLError(.badServerResponse)))
            }
            completion(.success(()))
        }.resume()
    }

    private func abort(transferID: String, baseURL: String, completion: @escaping (Result<Void, Error>) -> Void) {
        var req = URLRequest(url: URL(string: "\(baseURL)/macdrop/abort?id=\(transferID)")!)
        req.httpMethod = "POST"
        URLSession.shared.dataTask(with: req) { _, _, _ in completion(.success(())) }.resume()
    }

    // MARK: - 辅助

    /// 把拖进来的 URL 展开成文件列表，目录递归
    func expand(urls: [URL]) -> [FileItem] {
        var out: [FileItem] = []
        let base = urls.count == 1 ? urls[0].deletingLastPathComponent().standardizedFileURL : nil

        func walk(_ url: URL, prefix: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                guard let kids = try? fm.contentsOfDirectory(at: url,
                                                            includingPropertiesForKeys: [.isDirectoryKey]) else { return }
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
            let name = u.lastPathComponent
            if let base, base.standardizedFileURL == u.standardizedFileURL {
                walk(u, prefix: name)
            } else {
                walk(u, prefix: name)
            }
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