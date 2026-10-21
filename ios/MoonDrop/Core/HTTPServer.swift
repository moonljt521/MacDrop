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
        var state = 0 // 0=读头 1=读体 2=已应答
        var closing = false
        var stopped = false

        // keep-alive：应答后不关闭连接，继续处理同一连接上的下一个请求
        func respond(_ response: Response) {
            send(connection, response, keepAlive: !closing) {
                if closing {
                    connection.cancel()
                    return
                }
                buffer.removeAll(keepingCapacity: true)
                request = Request()
                expectedBody = 0
                state = 0
                receiveNext()
            }
        }

        func failAndClose(_ message: String) {
            closing = true
            stopped = true
            send(connection, .failure(message), keepAlive: false) { connection.cancel() }
        }

        func parseHeaderIfNeeded() {
            guard state == 0 else { return }
            guard let range = buffer.range(of: HTTPServer.headerEnd) else { return }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let parsed = HTTPServer.parseHeader(headerData) else {
                failAndClose("malformed header")
                return
            }
            request = parsed
            if request.headers["connection"]?.lowercased() == "close" { closing = true }
            expectedBody = Int(request.headers["content-length"] ?? "0") ?? 0
            // 单个分块 2 MB；异常/伪造的长度直接拒掉，避免被撑爆内存
            guard expectedBody <= Self.maxBodyBytes else {
                failAndClose("请求体过大")
                return
            }
            state = 1
        }

        func handleBodyIfComplete() {
            guard state == 1, buffer.count >= expectedBody else { return }
            request.body = Data(buffer.prefix(expectedBody))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + expectedBody))
            state = 2
            respond(handler(request))
        }

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if state == 0 {
                        parseHeaderIfNeeded()
                        if stopped { return }
                        if state == 0 {   // 头还没收全
                            receiveNext()
                            return
                        }
                    }
                    if state == 1 {
                        handleBodyIfComplete()
                        if state == 2 { return }   // 等应答写完再继续
                    }
                    receiveNext()
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveNext()
                }
            }
        }

        receiveNext()
    }

    private func send(_ connection: NWConnection,
                      _ response: Response,
                      keepAlive: Bool = true,
                      completion: @escaping () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(HTTPServer.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = keepAlive ? "keep-alive" : "close"
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
