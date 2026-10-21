import Foundation
import Network

/// 极简 HTTP/1.1 服务端，语义与 macOS 端一致。
final class HTTPServer {

    struct Request {
        var method = ""
        var path = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body = Data()
    }

    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(headers: ["Content-Type": "application/json"], body: data)
        }

        static func text(_ string: String, status: Int = 200) -> Response {
            Response(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(string.utf8))
        }

        static func failure(_ message: String, status: Int = 400) -> Response {
            .text(message, status: status)
        }
    }

    typealias Handler = (Request) -> Response

    private let requestedPort: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.macdrop.mobile.http", attributes: .concurrent)

    private(set) var listeningPort: UInt16 = 0
    var onReady: ((UInt16) -> Void)?
    var onFailure: ((Error) -> Void)?

    private static let headerEnd = Data("\r\n\r\n".utf8)
    /// 单个分块 2 MB，留出余量；超过就当成异常请求拒掉
    private static let maxBodyBytes = 32 * 1024 * 1024

    init(port: UInt16, handler: @escaping Handler) {
        requestedPort = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let port = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let actual = listener.port?.rawValue ?? self.requestedPort
                self.listeningPort = actual
                MobileLog.write("HTTP 监听 \(actual)")
                self.onReady?(actual)
            case .failed(let error):
                MobileLog.write("HTTP 监听失败：\(error)")
                self.onFailure?(error)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        var request = Request()
        var expectedBody = 0
        var state = 0

        func failAndClose(_ message: String) {
            send(connection, .failure(message)) { connection.cancel() }
        }

        func parseHeaderIfNeeded() -> Bool {
            guard state == 0 else { return false }
            guard let range = buffer.range(of: HTTPServer.headerEnd) else { return false }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let parsed = HTTPServer.parseHeader(headerData) else {
                failAndClose("malformed header")
                return true
            }
            request = parsed
            expectedBody = Int(request.headers["content-length"] ?? "0") ?? 0
            // 单个分块 2 MB；异常/伪造的长度直接拒掉，避免被撑爆内存
            guard expectedBody <= Self.maxBodyBytes else {
                failAndClose("请求体过大")
                return true
            }
            state = 1
            return false
        }

        func handleBodyIfComplete() -> Bool {
            guard state == 1 else { return false }
            guard buffer.count >= expectedBody else { return false }
            request.body = buffer.prefix(expectedBody)
            state = 2
            send(connection, handler(request)) { connection.cancel() }
            return true
        }

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if !parseHeaderIfNeeded(), !handleBodyIfComplete() {
                        receiveNext()
                        return
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receiveNext()
            }
        }

        receiveNext()
    }

    private func send(_ connection: NWConnection,
                      _ response: Response,
                      completion: @escaping () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        var output = Data(head.utf8)
        output.append(response.body)
        connection.send(content: output, completion: .contentProcessed { _ in completion() })
    }

    static func parseHeader(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var request = Request()
        request.method = parts[0]
        let target = parts[1]
        if let question = target.firstIndex(of: "?") {
            request.path = String(target[target.startIndex..<question])
            request.query = parseQuery(String(target[target.index(after: question)...]))
        } else {
            request.path = target
        }

        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            request.headers[key] = value
        }
        return request
    }

    static func parseQuery(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let keyPart = parts.first else { continue }
            let key = String(keyPart).removingPercentEncoding ?? String(keyPart)
            let value = parts.count > 1
                ? (String(parts[1]).removingPercentEncoding ?? String(parts[1]))
                : ""
            result[key] = value
        }
        return result
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
