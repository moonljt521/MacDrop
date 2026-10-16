import Foundation
import Network

/// 极简 HTTP/1.1 服务端，基于 Network.framework。
/// 只实现 MacDrop 需要的语义，避免引入第三方依赖。
final class HTTPService {

    struct Request {
        var method: String = ""
        var path: String = ""
        var query: [String: String] = [:]
        var headers: [String: String] = [:]
        var body: Data = Data()
        var remoteHost: String = ""

        /// 是否来自本机（用于限制 /macdrop/quit 这类高权限接口）
        var isLocalConnection: Bool {
            remoteHost == "127.0.0.1" || remoteHost == "::1" || remoteHost.hasPrefix("127.")
        }
    }

    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ obj: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            return Response(status: 200,
                            headers: ["Content-Type": "application/json"],
                            body: data)
        }

        static func text(_ s: String, status: Int = 200) -> Response {
            Response(status: status,
                     headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(s.utf8))
        }

        static func failure(_ message: String, status: Int = 400) -> Response {
            .text(message, status: status)
        }
    }

    typealias Handler = (Request) -> Response

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.macdrop.http", attributes: .concurrent)

    private static let crlf = Data("\r\n".utf8)
    private static let headerEnd = Data("\r\n\r\n".utf8)

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                NSLog("[MacDrop] HTTP 监听失败: \(err)")
            }
            if case .ready = state, let p = self?.listener?.port {
                NSLog("[MacDrop] HTTP 服务已启动，端口 \(p.rawValue)")
            }
        }
        listener = l
        l.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        var request = Request()
        var expectedBody = 0
        var state = 0 // 0=读头 1=读体

        func failAndClose(_ msg: String) {
            send(conn, .failure(msg)) { conn.cancel() }
        }

        func processBuffer() -> Bool {
            guard state == 0 else { return false }
            guard let range = buffer.range(of: HTTPService.headerEnd) else { return false }
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let parsed = HTTPService.parseHeader(headerData) else {
                failAndClose("malformed header"); return true
            }
            request = parsed
            if case let .hostPort(host, _) = conn.endpoint {
                request.remoteHost = "\(host)"
            }
            expectedBody = Int(request.headers["content-length"] ?? "0") ?? 0
            state = 1
            return false
        }

        func readBodyIfComplete() -> Bool {
            guard state == 1 else { return false }
            guard buffer.count >= expectedBody else { return false }
            request.body = buffer.prefix(expectedBody)
            state = 2
            send(conn, handler(request)) { conn.cancel() }
            return true
        }

        func receiveNext() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if !processBuffer(), !readBodyIfComplete() {
                        receiveNext()
                        return
                    }
                } else if isComplete || error != nil {
                    conn.cancel()
                    return
                }
                receiveNext()
            }
        }

        receiveNext()
    }

    private func send(_ conn: NWConnection, _ resp: Response, completion: @escaping () -> Void) {
        var head = "HTTP/1.1 \(resp.status) \(HTTPService.reason(resp.status))\r\n"
        var headers = resp.headers
        headers["Content-Length"] = String(resp.body.count)
        headers["Connection"] = "close"
        for (k, v) in headers {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { _ in completion() })
    }

    // MARK: - 解析

    static func parseHeader(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var req = Request()
        req.method = parts[0]
        let target = parts[1]
        if let q = target.firstIndex(of: "?") {
            req.path = String(target[target.startIndex..<q])
            req.query = parseQuery(String(target[target.index(after: q)...]))
        } else {
            req.path = target
        }

        for line in lines.dropFirst() where !line.isEmpty {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = String(line[line.startIndex..<c]).lowercased()
            let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            req.headers[k] = v
        }
        return req
    }

    static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first else { continue }
            let key = String(k).removingPercentEncoding ?? String(k)
            let val = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            out[key] = val
        }
        return out
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