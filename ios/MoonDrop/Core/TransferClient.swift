import Foundation

/// 发送端：与 macOS 端一致，announce → 顺序 2 MiB 分块 → finish。
final class TransferClient {

    private let chunkSize = 2 * 1024 * 1024

    func send(files: [OutgoingFile],
              to peer: Peer,
              progress: @escaping (_ sent: Int64, _ total: Int64, _ currentFile: String) -> Void,
              completion: @escaping (Result<Void, Error>) -> Void) {

        guard !files.isEmpty else {
            completion(.success(()))
            return
        }

        let base = "http://\(peer.host):\(peer.port)"
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var sentTotal: Int64 = 0
        progress(0, total, files[0].url.lastPathComponent)

        func next(_ index: Int) {
            guard index < files.count else {
                completion(.success(()))
                return
            }
            let file = files[index]
            let transferID = UUID().uuidString
            let rootName = file.relativePath.contains("/")
                ? String(file.relativePath.split(separator: "/").first ?? "")
                : nil

            announce(transferID: transferID,
                     fileName: file.url.lastPathComponent,
                     relativePath: file.relativePath,
                     size: file.size,
                     rootName: rootName,
                     baseURL: base) { result in
                switch result {
                case .failure(let error):
                    MobileLog.write("发送失败 \(file.url.lastPathComponent)：\(error)")
                    completion(.failure(error))
                case .success:
                    self.upload(file: file,
                                transferID: transferID,
                                baseURL: base,
                                onBytes: { count in
                                    sentTotal += Int64(count)
                                    progress(sentTotal, total, file.url.lastPathComponent)
                                }) { uploadResult in
                        switch uploadResult {
                        case .success:
                            next(index + 1)
                        case .failure(let error):
                            self.abort(transferID: transferID, baseURL: base)
                            completion(.failure(error))
                        }
                    }
                }
            }
        }

        next(0)
    }

    // MARK: - 分块上传

    private func upload(file: OutgoingFile,
                        transferID: String,
                        baseURL: String,
                        onBytes: @escaping (Int) -> Void,
                        completion: @escaping (Result<Void, Error>) -> Void) {

        guard let handle = try? FileHandle(forReadingFrom: file.url) else {
            completion(.failure(NSError(domain: "MoonDropMobile", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "无法读取文件"
            ])))
            return
        }

        var offset: Int64 = 0

        // 句柄必须活到最后一个分块发完：不能在启动异步上传后就关闭。
        func finishAndClose() {
            finish(transferID: transferID, baseURL: baseURL) { result in
                try? handle.close()
                completion(result)
            }
        }

        func failAndClose(_ error: Error) {
            try? handle.close()
            completion(.failure(error))
        }

        func sendNext() {
            guard offset < file.size else {
                finishAndClose()
                return
            }
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else {
                failAndClose(NSError(domain: "MoonDropMobile", code: 500, userInfo: [
                    NSLocalizedDescriptionKey: "读取提前结束（\(offset)/\(file.size) 字节）"
                ]))
                return
            }

            let currentOffset = offset
            offset += Int64(data.count)

            guard let url = URL(string: "\(baseURL)/macdrop/chunk?id=\(transferID)&offset=\(currentOffset)") else {
                failAndClose(URLError(.badURL))
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

            URLSession.shared.uploadTask(with: request, from: data) { _, response, error in
                if let error { return failAndClose(error) }
                guard let code = (response as? HTTPURLResponse)?.statusCode,
                      (200..<300).contains(code) else {
                    return failAndClose(URLError(.badServerResponse))
                }
                onBytes(data.count)
                sendNext()
            }.resume()
        }

        sendNext()
    }

    // MARK: - HTTP 辅助

    private func announce(transferID: String,
                          fileName: String,
                          relativePath: String,
                          size: Int64,
                          rootName: String?,
                          baseURL: String,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        var components = URLComponents(string: "\(baseURL)/macdrop/begin")
        components?.queryItems = [
            URLQueryItem(name: "id", value: transferID),
            URLQueryItem(name: "name", value: fileName),
            URLQueryItem(name: "path", value: relativePath),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "root", value: rootName ?? "")
        ]
        guard let url = components?.url else {
            completion(.failure(URLError(.badURL)))
            return
        }
        post(url, completion: completion)
    }

    private func finish(transferID: String,
                        baseURL: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: "\(baseURL)/macdrop/finish?id=\(transferID)") else {
            completion(.failure(URLError(.badURL)))
            return
        }
        post(url, completion: completion)
    }

    private func abort(transferID: String, baseURL: String) {
        guard let url = URL(string: "\(baseURL)/macdrop/abort?id=\(transferID)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request).resume()
    }

    private func post(_ url: URL,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let code = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(code) else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            completion(.success(()))
        }.resume()
    }
}
