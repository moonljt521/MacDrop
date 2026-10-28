import Foundation

/// Bonjour 发现 + 本机广播，协议与 macOS 端一致：_macdrop._tcp
/// TXT 里额外带一个稳定的 id，用于可靠地过滤掉自己（Mac 端不读 TXT，不受影响）。
final class PeerBrowser: NSObject {

    var onPeersChanged: (([Peer]) -> Void)?

    private let serviceType = "_macdrop._tcp."
    private let domain = "local."
    private let ownID: String

    private var advertiser: NetService?
    private var browser: NetServiceBrowser?
    private var ownName = ""
    private var ownPort: UInt16 = 0

    private var resolving = Set<NetService>()
    private var byServiceName: [String: Peer] = [:]
    private var peers: [Peer] = []

    init(ownID: String) {
        self.ownID = ownID
        super.init()
    }

    func advertise(name: String, port: UInt16) {
        advertiser?.stop()
        ownName = name
        ownPort = port

        let service = NetService(domain: domain,
                                 type: serviceType,
                                 name: name,
                                 port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(ownID.utf8)]))
        service.publish()
        advertiser = service
        MobileLog.write("广播 \(name) :\(port)")
    }

    func browse() {
        browser?.stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: domain)
        self.browser = browser
        MobileLog.write("开始浏览对端")
    }

    func stop() {
        advertiser?.stop()
        advertiser = nil
        browser?.stop()
        browser = nil
        resolving.removeAll()
    }

    private func isSelf(_ service: NetService) -> Bool {
        if let data = service.txtRecordData() {
            let record = NetService.dictionary(fromTXTRecord: data)
            if let idData = record["id"],
               let id = String(data: idData, encoding: .utf8) {
                return id == ownID
            }
        }
        let host = (service.hostName ?? "").lowercased()
        return service.name == ownName
            && UInt16(clamping: service.port) == ownPort
            && !host.isEmpty
            && host.contains(ProcessInfo.processInfo.hostName.lowercased())
    }

    /// 本机自己也会被 Bonjour 浏览到。解析出地址后，如果端口与本机监听端口一致、
    /// 且地址属于本机网卡，就可以确定是自己（TXT 记录有时要等到解析后才读得到）。
    private func isResolvedSelf(host: String, port: UInt16) -> Bool {
        guard port == ownPort else { return false }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return PeerBrowser.localAddresses().contains(bare)
    }

    private static func localAddresses() -> Set<String> {
        var result = Set<String>()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(address.pointee.sa_len)
            guard getnameinfo(address, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if let zone = ip.firstIndex(of: "%") {
                result.insert(String(ip[..<zone]))
            } else {
                result.insert(ip)
            }
        }
        return result
    }

    private func upsert(_ peer: Peer, serviceName: String) {
        byServiceName[serviceName] = peer
        peers = byServiceName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        publish()
    }

    private func remove(serviceName: String) {
        byServiceName.removeValue(forKey: serviceName)
        peers = byServiceName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        publish()
    }

    private func publish() {
        let snapshot = peers
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(snapshot)
        }
    }

    /// 按可用性排序的地址列表：局域网可路由 IPv4 优先，
    /// 最后才是 169.254 链路本地（AWDL，首次建链要 1~2 秒）
    private static func candidates(from addresses: [Data]) -> [(ip: String, score: Int)] {
        var result: [(ip: String, score: Int)] = []
        for data in addresses {
            guard let (ip, isV6) = hostAddress(from: data) else { continue }
            result.append((ip, score(ip: ip, isV6: isV6)))
        }
        return result.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score < rhs.element.score }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    private static func score(ip: String, isV6: Bool) -> Int {
        if !isV6 {
            if ip.hasPrefix("169.254.") { return 3 }     // 链路本地：AWDL
            if isPrivateIPv4(ip) { return 0 }             // 10/172.16-31/192.168
            return 1
        }
        return ip.lowercased().hasPrefix("fe80:") ? 4 : 2
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }

    private static func hostAddress(from data: Data) -> (String, Bool)? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }

        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyBytes(from: data)
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let (length, family) = withUnsafePointer(to: &storage) { pointer -> (socklen_t, sa_family_t) in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                let len = address.pointee.sa_len
                return (len > 0 ? socklen_t(len) : socklen_t(data.count),
                        address.pointee.sa_family)
            }
        }
        let result = withUnsafePointer(to: &storage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                getnameinfo(address, length, &host, socklen_t(host.count),
                            nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        let ip = String(cString: host)
        guard !ip.isEmpty else { return nil }
        return (ip, family == sa_family_t(AF_INET6))
    }
}

extension PeerBrowser: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        guard !isSelf(service) else { return }
        MobileLog.write("发现对端：\(service.name)")
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        MobileLog.write("对端消失：\(service.name)")
        resolving.remove(service)
        remove(serviceName: service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        MobileLog.write("浏览失败：\(errorDict)")
    }
}

extension PeerBrowser: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.remove(sender)
        let candidates = PeerBrowser.candidates(from: sender.addresses ?? [])
        guard let best = candidates.first else {
            MobileLog.write("解析地址失败：\(sender.name)")
            return
        }
        if isSelf(sender) || isResolvedSelf(host: best.ip, port: UInt16(clamping: sender.port)) {
            remove(serviceName: sender.name)
            return
        }
        var alternatives = candidates.dropFirst().map { $0.ip }
        // 数字 IP 可能因 DHCP 变更过期；把 Bonjour 主机名也作为兜底地址
        if let hostName = sender.hostName {
            let trimmed = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
            if !trimmed.isEmpty, trimmed.lowercased() != "local",
               !alternatives.contains(trimmed), trimmed != best.ip {
                alternatives.append(trimmed)
            }
        }
        upsert(Peer(name: sender.name, host: best.ip, port: UInt16(clamping: sender.port),
                    alternatives: alternatives),
               serviceName: sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.remove(sender)
        MobileLog.write("解析超时：\(sender.name)")
    }
}
