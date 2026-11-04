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
    /// 通过点对点（AWDL）连上：对方不在当前 Wi-Fi，而是在附近直连
    var isPeerToPeer: Bool = false

    /// 去重用的地址键：设备改名后 Bonjour 实例名会变，按它才能认出是同一台
    var endpoint: String { "\(host):\(port)" }

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
    private var servicePeers: [String: String] = [:]   // service name -> peer endpoint
    private var pendingRemovals: [String: DispatchWorkItem] = [:]
    /// 解析失败的服务 → 重试任务；mDNS 在拥挤的 Wi-Fi 上偶发超时，一次失败不能永久看不见
    private var resolveRetries: [String: DispatchWorkItem] = [:]
    private var resolveAttempts: [String: Int] = [:]
    /// 自己广告出去的实例名（重名时会被加上后缀）
    private var ownName: String = ""
    /// 用户想要显示的名字；实例名冲突时只在后面加 (2)、(3)…
    private var baseName: String = ""
    private var instanceSuffix = 0
    private var publishFailures = 0
    private var publishRetry: DispatchWorkItem?
    /// 自己广播用的端口，和主机名一起用于唯一识别本机
    private var ownPort: UInt16 = 0
    /// 广播是否真的上线（didPublish 过）；没上线时看门狗会重发
    private var published = false
    /// 最近一次任何 Bonjour 回调的时间；太久没有回调说明浏览已经死掉
    private var lastActivity = Date()
    private var healthTimer: DispatchSourceTimer?

    private(set) var peers: [Peer] = []
    var onPeersChanged: (([Peer]) -> Void)?
    /// 广播是否已确认上线（对端能不能看到我）
    var isAdvertiseLive: Bool { published }

    private let lock = NSLock()

    /// 浏览/广告静默多久后自愈
    private static let staleAfter: TimeInterval = 40
    private static let healthInterval: TimeInterval = 12

    // MARK: - 广告本机

    func advertise(name: String, port: UInt16) {
        stopAdvertising()
        // 只有用户真的改名才从头开始；换端口/重新发布要保留已经避过撞车的后缀
        if baseName != name {
            baseName = name
            instanceSuffix = 0
        }
        publishFailures = 0
        ownPort = port
        publishInstance()
        startHealthTimer()
    }

    /// 实例名在同一网段里必须唯一。重名时第二台会直接发布失败并永远不被发现
    /// （实测 -72001），所以失败两次就换 "名字 (2)" 再发。
    private func publishInstance() {
        let instanceName = instanceSuffix == 0 ? baseName : "\(baseName) (\(instanceSuffix))"
        ownName = instanceName
        if let old = advertiser {
            old.delegate = nil
            old.stop()
        }
        let svc = NetService(domain: BonjourService.domain,
                             type: BonjourService.serviceType,
                             name: instanceName,
                             port: Int32(ownPort))
        svc.delegate = self
        // TXT 带一个装机生成的稳定 id，方便对端识别与排查；不靠它过滤自己
        svc.setTXTRecord(NetService.data(fromTXTRecord: [
            "id": Data(Config.shared.deviceID.utf8)
        ]))
        published = false
        svc.publish()
        advertiser = svc
        NSLog("[MoonDrop] Bonjour 广告启动: \(instanceName) (端口 \(ownPort))")
    }

    private func scheduleRepublish() {
        publishRetry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.publishRetry = nil
            guard self.advertiser != nil, !self.published else { return }
            self.publishInstance()
        }
        publishRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func stopAdvertising() {
        publishRetry?.cancel()
        publishRetry = nil
        advertiser?.delegate = nil
        advertiser?.stop()
        advertiser = nil
        published = false
    }

    // MARK: - 浏览对端

    func browse() {
        browser?.stop()
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: BonjourService.serviceType,
                            inDomain: BonjourService.domain)
        browser = b
        lastActivity = Date()
        NSLog("[MoonDrop] Bonjour 浏览启动")
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    /// 广播静默失败 / 浏览线程被系统回收时，光靠回调等不到任何东西。
    /// 这个看门狗只做两件幂等的事：没发布成功就重发，长时间没有回调就重启浏览。
    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.macdrop.bonjour.health")
        )
        timer.schedule(deadline: .now() + Self.healthInterval, repeating: Self.healthInterval)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        // Bonjour 回调、广播、重试都在主线程，看门狗也切回主线程，避免多线程读写同一组状态
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.advertiser != nil, !self.published {
                NSLog("[MoonDrop] Bonjour 广告未上线，重新发布")
                self.scheduleRepublish()
            }
            if self.browser != nil, Date().timeIntervalSince(self.lastActivity) > Self.staleAfter {
                NSLog("[MoonDrop] Bonjour 浏览超过 \(Int(Self.staleAfter)) 秒无回调，重启浏览")
                self.browse()
            }
        }
    }

    private func touch() {
        lastActivity = Date()
    }

    // MARK: - 对端表

    private func upsert(_ peer: Peer, serviceName: String? = nil) {
        lock.lock()
        if let serviceName {
            // 同一台设备换了 IP（DHCP 续租/切网）：旧地址那条要撤掉，否则列表里出现两个它
            if let previous = servicePeers[serviceName], previous != peer.endpoint {
                peers.removeAll { $0.endpoint == previous }
            }
            servicePeers[serviceName] = peer.endpoint
        }
        // 按地址去重：设备改名后 Bonjour 名字会变，按名字会出现两条同一台设备
        if let idx = peers.firstIndex(where: { $0.endpoint == peer.endpoint }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.unlock()
        notify()
    }

    /// 扫描 / 手动添加得到的对端
    func addDirect(_ peer: Peer) {
        upsert(peer)
    }

    /// 只移除消失的那一台设备；不能因为一次 lost 事件清空整个列表。
    private func remove(serviceName: String) {
        lock.lock()
        pendingRemovals.removeValue(forKey: serviceName)
        resolveRetries.removeValue(forKey: serviceName)?.cancel()
        resolveAttempts.removeValue(forKey: serviceName)
        if let endpoint = servicePeers.removeValue(forKey: serviceName) {
            peers.removeAll { $0.endpoint == endpoint }
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
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            var peerName = name
            if peerName.isEmpty || peerName == "手动对端" {
                if let data,
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let reported = object["device"] as? String, !reported.isEmpty {
                    peerName = reported
                }
            }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            if ok {
                self.upsert(Peer(host: host, port: port,
                                 name: peerName.isEmpty ? host : peerName,
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
        touch()
        // 过滤掉自己。注意：不能用显示名判断——两台机器可能都叫 "MacBook Pro"，
        // 会把对方误当成自己滤掉（实测踩过：Bonjour 会把重名的后者改名成 "MacBook Pro (2)"，
        // 但两边都叫这个名字，结果互相看不见）。
        // 这里只允许「名字 + 端口 + 主机名」三者同时命中才早退，解析成功后还会再查一次本机地址。
        let localHost = ProcessInfo.processInfo.hostName.lowercased()
        let serviceHost = (service.hostName ?? "").lowercased()
        if !localHost.isEmpty,
           service.name == ownName,
           Int32(ownPort) == service.port,
           !serviceHost.isEmpty,
           serviceHost.contains(localHost) {
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
        touch()
        NSLog("[MoonDrop] 对端消失: \(service.name)")
        resolving.remove(service)
        scheduleRemoval(serviceName: service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        // 常见于本地网络权限还没批下来：批完权限后浏览不会自己恢复，必须重启
        NSLog("[MoonDrop] Bonjour 浏览失败: \(errorDict)，\(Int(Self.staleAfter)) 秒内自动重试")
        lastActivity = .distantPast
    }
}

extension BonjourService: NetServiceDelegate {
    func netServiceDidPublish(_ sender: NetService) {
        touch()
        published = true
        publishFailures = 0
        NSLog("[MoonDrop] Bonjour 广告已上线: \(sender.name) (端口 \(sender.port))")
    }

    /// 本地网络权限被拒时，注册可能既不成功也不报错；这里必须留痕，否则问题无从排查。
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        touch()
        published = false
        publishFailures += 1
        if publishFailures >= 2 {
            // 连发两次都失败，几乎可以确定是实例名撞车
            instanceSuffix += 1
            publishFailures = 0
            NSLog("[MoonDrop] 广播名「\(baseName)」被占用，改用「\(baseName) (\(instanceSuffix))」重试")
        }
        NSLog("[MoonDrop] Bonjour 广告失败: \(errorDict)")
        scheduleRepublish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        touch()
        resolving.remove(sender)
        resolveAttempts.removeValue(forKey: sender.name)
        cancelPendingRemoval(serviceName: sender.name)
        let candidates = BonjourService.candidates(from: sender.addresses ?? [])
        guard let best = candidates.first else {
            NSLog("[MoonDrop] 解析地址失败: \(sender.name)")
            scheduleResolveRetry(sender)
            return
        }
        // 解析出来的地址属于本机网卡且端口一致，就是自己（重名机器上比名字可靠）
        if UInt16(clamping: sender.port) == ownPort,
           BonjourService.localAddresses().contains(best.ip) {
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
                    alternatives: alternatives,
                    isPeerToPeer: best.ip.hasPrefix("169.254.")),
               serviceName: sender.name)
    }

    func netService(_ sender: NetService,
                    didNotResolve errorDict: [String: NSNumber]) {
        touch()
        resolving.remove(sender)
        NSLog("[MoonDrop] 解析超时: \(sender.name) \(errorDict)")
        scheduleResolveRetry(sender)
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {}

    /// Wi-Fi 拥挤时一次解析超时很常见，放弃就等于这台设备从此不再出现在列表里。
    /// 按 2/5/10 秒重试三轮，还在就当作真的不可达，等下一次 lost/didFind。
    private func scheduleResolveRetry(_ service: NetService) {
        let attempts = (resolveAttempts[service.name] ?? 0) + 1
        resolveAttempts[service.name] = attempts
        guard attempts <= 3 else {
            resolveAttempts.removeValue(forKey: service.name)
            return
        }
        let delay = [2.0, 5.0, 10.0][attempts - 1]
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resolveRetries.removeValue(forKey: service.name)
            guard !self.resolving.contains(service) else { return }
            self.resolving.insert(service)
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
        resolveRetries[service.name]?.cancel()
        resolveRetries[service.name] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 本机网卡上的地址，用来认出「自己广告的服务」
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
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if let zone = ip.firstIndex(of: "%") {
                result.insert(String(ip[..<zone]))
            } else {
                result.insert(ip)
            }
        }
        return result
    }

    /// 按可用性排序的地址列表：
    /// 1. 本机所在网段的私有 IPv4（最稳）
    /// 2. 链路本地 169.254（AWDL 点对点）——对方不在当前 Wi-Fi 时，只有这条路通
    /// 3. 对方别的网段的私有 IPv4（走不通，留作兜底）
    /// 4. 其它 IPv4
    /// 5. IPv6（全局优先于 fe80 链路本地）
    private static func candidates(from addresses: [Data]) -> [(ip: String, score: Int)] {
        let prefixes = ourSubnetPrefixes()
        var result: [(ip: String, score: Int)] = []
        for data in addresses {
            guard let (ip, isV6) = hostAddress(from: data) else { continue }
            result.append((ip, score(ip: ip, isV6: isV6, prefixes: prefixes)))
        }
        return result.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.score != rhs.element.score { return lhs.element.score < rhs.element.score }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
    }

    /// 本机各 IPv4 网卡的 /24 网段前缀，例如 ["10.0.1", "192.168.0"]
    private static func ourSubnetPrefixes() -> Set<String> {
        var result = Set<String>()
        for ip in localAddresses() where !ip.contains(":") && !ip.hasPrefix("169.254.") {
            let parts = ip.split(separator: ".").map(String.init)
            if parts.count == 4 { result.insert(parts[0...2].joined(separator: ".")) }
        }
        return result
    }

    private static func score(ip: String, isV6: Bool, prefixes: Set<String>) -> Int {
        if !isV6 {
            if ip.hasPrefix("169.254.") { return 1 }     // 链路本地：AWDL 点对点
            if isPrivateIPv4(ip) {
                let parts = ip.split(separator: ".").map(String.init)
                return parts.count == 4 && prefixes.contains(parts[0...2].joined(separator: ".")) ? 0 : 2
            }
            return 3
        }
        return ip.lowercased().hasPrefix("fe80:") ? 5 : 4
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