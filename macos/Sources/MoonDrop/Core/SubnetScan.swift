import Foundation

/// 不依赖 mDNS 的兜底发现：扫描本机所在网段的 52345 端口。
///
/// 为什么需要：部分路由器（尤其企业/酒店 Wi-Fi、开了 IGMP snooping 的 AP）会屏蔽组播，
/// Bonjour 的广播和查询全都出不去，各端「在线且在同一 Wi-Fi」却互相看不见。
/// 单播 TCP 通常仍然放行，于是直接 ping 一遍同网段地址就能把人找回来。
/// 局限：只能找到监听默认端口 52345 的设备，跨网段/开了客户端隔离的网络仍然无效。
enum SubnetScan {

    struct Found: Equatable {
        let host: String
        let port: UInt16
        let name: String
    }

    private static let defaultPort: UInt16 = 52345
    /// 单次扫描的硬时限：客户端隔离的网络里每个地址都要等到超时，不能让人等下去
    private static let deadline: TimeInterval = 12

    /// 在后台执行，结果在主线程回调。
    static func run(completion: @escaping ([Found]) -> Void) {
        let candidates = candidateHosts()
        if candidates.isEmpty {
            DispatchQueue.main.async { completion([]) }
            return
        }
        let bucketCount = min(32, candidates.count)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.macdrop.scan", attributes: .concurrent)
        let resultLock = NSLock()
        var found: [Found] = []
        let started = Date()

        for bucket in 0..<bucketCount {
            group.enter()
            DispatchQueue.global().async {
                var index = bucket
                while index < candidates.count {
                    if Date().timeIntervalSince(started) > deadline { break }
                    if let hit = probe(candidates[index]) {
                        resultLock.lock()
                        found.append(hit)
                        resultLock.unlock()
                    }
                    index += bucketCount
                }
                group.leave()
            }
        }

        group.notify(queue: queue) {
            NSLog("[MoonDrop] 局域网扫描完成：探测 \(candidates.count) 个地址，命中 \(found.count) 台")
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// 本机各网卡所在 /24 段的 .1–.254（排除本机自己）
    private static func candidateHosts() -> [String] {
        let local = localIPv4s()
        var hosts = Set<String>()
        for (ip, _) in local {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            for last in 1...254 {
                let candidate = "\(parts[0]).\(parts[1]).\(parts[2]).\(last)"
                if local.contains(where: { $0.0 == candidate }) { continue }
                hosts.insert(candidate)
            }
        }
        return hosts.sorted()
    }

    private static func probe(_ host: String) -> Found? {
        guard let url = URL(string: "http://\(host):\(defaultPort)/macdrop/ping") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
        request.httpMethod = "GET"
        let done = DispatchSemaphore(value: 0)
        var result: Found?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let port = UInt16(clamping: (object["port"] as? Int) ?? Int(defaultPort))
            let name = (object["device"] as? String) ?? host
            result = Found(host: host, port: port, name: name.isEmpty ? host : name)
        }.resume()
        // 连不通时（客户端隔离/防火墙） URLSession 会自己超时，这里只多给一点余量
        _ = done.wait(timeout: .now() + 1.5)
        return result
    }

    /// 本机 IPv4 地址 + 掩码（点分十进制）
    static func localIPv4s() -> [(String, String)] {
        var result: [(String, String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  let mask = entry.pointee.ifa_netmask,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = numeric(address)
            let netmask = numeric(mask)
            if ip.isEmpty || ip.hasPrefix("127.") { continue }
            result.append((ip, netmask))
        }
        return result
    }

    private static func numeric(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                          socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: host)
    }
}
