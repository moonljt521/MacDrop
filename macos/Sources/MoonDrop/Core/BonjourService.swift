import Foundation

/// 局域网内的对端设备
struct Peer: Identifiable, Equatable {
    /// 用「主机名 + 端口」做唯一标识：IP 可能变（DHCP），
    /// 主机名+端口在同一台机器上更稳定。
    var id: String { "\(name)@\(host):\(port)" }
    var host: String
    var port: UInt16
    var name: String
    var isManual: Bool = false
    /// 同一台设备的其它可用地址：首选地址连不通时依次尝试
    var alternatives: [String] = []

    static func == (a: Peer, b: Peer) -> Bool { a.id == b.id }
}

/// Bonjour 服务：广告本机 + 浏览对端。
/// 用 NetService（Swift 6 下 API 已改名，兼容处理过）。
final class BonjourService: NSObject {

    private static let serviceType = "_macdrop._tcp"
    private static let domain = "local."

    private var advertiser: NetService?
    private var browser: NetServiceBrowser?
    private var resolving: Set<NetService> = []
    private var servicePeers: [String: String] = [:]   // service name -> peer id
    private var pendingRemovals: [String: DispatchWorkItem] = [:]
    /// 自己广告出去的名字，用来过滤「自己发现自己」
    private var ownName: String = ""
    /// 自己广播用的端口，和主机名一起用于唯一识别本机
    private var ownPort: UInt16 = 0

    private(set) var peers: [Peer] = []
    var onPeersChanged: (([Peer]) -> Void)?

    private let lock = NSLock()

    // MARK: - 广告本机

    func advertise(name: String, port: UInt16) {
        stopAdvertising()
        ownName = name
        ownPort = port
        let svc = NetService(domain: BonjourService.domain,
                             type: BonjourService.serviceType,
                             name: name,
                             port: Int32(port))
        svc.delegate = self
        svc.setTXTRecord(Data())
        svc.publish()
        advertiser = svc
        NSLog("[MoonDrop] Bonjour 广告启动: \(name)")
    }

    func stopAdvertising() {
        advertiser?.stop()
        advertiser = nil
    }

    // MARK: - 浏览对端

    func browse() {
        browser?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: BonjourService.serviceType,
                            inDomain: BonjourService.domain)
        browser = b
        NSLog("[MoonDrop] Bonjour 浏览启动")
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    // MARK: - 对端表

    private func upsert(_ peer: Peer, serviceName: String? = nil) {
        lock.lock()
        if let serviceName {
            servicePeers[serviceName] = peer.id
        }
        // 按地址去重：设备改名后 Bonjour 名字会变，按 id 会出现两条同一台设备
        if let idx = peers.firstIndex(where: { $0.host == peer.host && $0.port == peer.port }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.unlock()
        notify()
    }

    /// 只移除消失的那一台设备；不能因为一次 lost 事件清空整个列表。
    private func remove(serviceName: String) {
        lock.lock()
        pendingRemovals.removeValue(forKey: serviceName)
        if let peerID = servicePeers.removeValue(forKey: serviceName) {
            peers.removeAll { $0.id == peerID }
        } else {
            peers.removeAll { !$0.isManual && $0.name == serviceName }
        }
        lock.unlock()
        notify()
    }

    /// mDNS 会偶发 lost，延迟几秒再移除；期间若重新发现就取消。
    private func scheduleRemoval(serviceName: String) {
        let work = DispatchWorkItem { [weak self] in
            self?.remove(serviceName: serviceName)
        }
        lock.lock()
        pendingRemovals.removeValue(forKey: serviceName)?.cancel()
        pendingRemovals[serviceName] = work
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func cancelPendingRemoval(serviceName: String) {
        lock.lock()
        let work = pendingRemovals.removeValue(forKey: serviceName)
        lock.unlock()
        work?.cancel()
    }

    private func notify() {
        lock.lock()
        let snapshot = peers
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(snapshot)
        }
    }

    /// 不依赖 Bonjour 的直连兜底（防火墙 / 网络隔离时用）
    func probeManual(host: String, port: UInt16, name: String,
                     completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(host):\(port)/macdrop/ping") else {
            completion(false); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok {
                self.upsert(Peer(host: host, port: port,
                                 name: name.isEmpty ? host : name,
                                 isManual: true))
            }
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }
}

extension BonjourService: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didFind service: NetService,
                           moreComing: Bool) {
        // 过滤掉自己。注意：不能用显示名判断——两台机器可能都叫 "MacBook Pro"，
        // 会把对方误当成自己滤掉（实测踩过：Bonjour 会把重名的后者改名成 "MacBook Pro (2)"，
        // 但两边都叫这个名字，结果互相看不见）。
        // 改用「本机主机名 + 端口」这一组唯一性更高的特征。
        let localHost = ProcessInfo.processInfo.hostName
        let serviceHost = (service.hostName ?? "").lowercased()
        if service.name == ownName,
           Int32(ownPort) == service.port,
           !serviceHost.isEmpty,
           serviceHost.contains(localHost.lowercased()) {
            return
        }
        cancelPendingRemoval(serviceName: service.name)
        NSLog("[MoonDrop] 发现对端: \(service.name)")
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        NSLog("[MoonDrop] 对端消失: \(service.name)")
        resolving.remove(service)
        scheduleRemoval(serviceName: service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        NSLog("[MoonDrop] Bonjour 浏览失败: \(errorDict)")
    }
}

extension BonjourService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[MoonDrop] Bonjour 广告已上线: \(sender.name) (端口 \(sender.port))")
    }

    /// 本地网络权限被拒时，注册可能既不成功也不报错；这里必须留痕，否则问题无从排查。
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[MoonDrop] Bonjour 广告失败: \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        resolving.remove(sender)
        cancelPendingRemoval(serviceName: sender.name)
        let candidates = BonjourService.candidates(from: sender.addresses ?? [])
        guard let best = candidates.first else {
            NSLog("[MoonDrop] 解析地址失败: \(sender.name)")
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
        NSLog("[MoonDrop] 解析对端 \(sender.name) → \(best.ip):\(sender.port)")
        upsert(Peer(host: best.ip,
                    port: UInt16(clamping: sender.port),
                    name: sender.name,
                    alternatives: alternatives),
               serviceName: sender.name)
    }

    func netService(_ sender: NetService,
                    didNotResolve errorDict: [String: NSNumber]) {
        NSLog("[MoonDrop] 解析超时: \(sender.name)")
        resolving.remove(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {}

    /// 从一组地址里挑一个可直接拼进 http://host:port 的。
    /// 必须 IPv4 优先：URL 里 IPv6 要加方括号才合法，且 NetService 返回的地址顺序不稳定，
    /// 一旦取到裸 IPv6 就会拼出坏 URL，发送直接失败。
    /// 按可用性排序的地址列表。
    /// 局域网可路由 IPv4 优先，其次其它 IPv4，最后才是 169.254 链路本地（AWDL）。
    /// AWDL 首次建链要 1~2 秒，而局域网地址是现成的，能明显缩短首次传输的等待。
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

    /// 从 sockaddr Data 里取数字 IP，并返回是否 IPv6
    private static func hostAddress(from sockaddrData: Data) -> (String, Bool)? {
        // IPv4 的 sockaddr 只有 16 字节、IPv6 是 28 字节，都远小于 sockaddr_storage(128)，
        // 所以不能用 storage 的大小做下限校验，否则所有地址都会被挡掉。
        guard sockaddrData.count >= MemoryLayout<sockaddr>.size else { return nil }

        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            raw.copyBytes(from: sockaddrData)
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        // 用 sa_len 判断实际长度（Darwin 特有），IPv4 为 16、IPv6 为 28
        let (len, family) = withUnsafePointer(to: &storage) { ptr -> (socklen_t, sa_family_t) in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                let l = sa.pointee.sa_len
                return (l > 0 ? socklen_t(l) : socklen_t(sockaddrData.count), sa.pointee.sa_family)
            }
        }
        let result = withUnsafePointer(to: &storage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, len, &host, socklen_t(host.count),
                            nil, 0, NI_NUMERICHOST)
            }
        }
        guard result == 0 else { return nil }
        let ip = String(cString: host)
        guard !ip.isEmpty else { return nil }
        return (ip, family == sa_family_t(AF_INET6))
    }
}