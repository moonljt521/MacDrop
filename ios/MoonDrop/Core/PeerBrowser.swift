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
    private var baseName = ""
    private var instanceSuffix = 0
    private var publishFailures = 0
    private var publishRetry: DispatchWorkItem?
    private var ownPort: UInt16 = 0

    private var resolving = Set<NetService>()
    private var byServiceName: [String: Peer] = [:]
    private var peers: [Peer] = []
    /// mDNS 会偶发 lost，延迟几秒再移除；期间重新发现就取消
    private var pendingRemovals: [String: DispatchWorkItem] = [:]
    /// 解析超时后按 2/5/10 秒重试；一次超时就把设备丢掉，是「明明在线却看不见」的主因之一
    private var resolveRetries: [String: DispatchWorkItem] = [:]
    private var resolveAttempts: [String: Int] = [:]
    private var published = false
    private var lastActivity = Date()
    private var healthTimer: DispatchSourceTimer?

    private static let staleAfter: TimeInterval = 40
    private static let healthInterval: TimeInterval = 12

    /// 广播是否已确认上线（别人能不能看到我）
    var isAdvertiseLive: Bool { published }

    init(ownID: String) {
        self.ownID = ownID
        super.init()
    }

    func advertise(name: String, port: UInt16) {
        advertiser?.stop()
        // 只有用户真的改名才从头开始；回前台重发要保留已经避过撞车的后缀
        if baseName != name {
            baseName = name
            instanceSuffix = 0
        }
        publishFailures = 0
        ownPort = port
        publishInstance()
        startHealthTimer()
    }

    /// 实例名在全网段内必须唯一：两台设备同名时，后发布的那台会直接失败并永远不被发现
    /// （真机实测错误码 -72001），所以失败两次就换成「名字 (2)」再发。
    private func publishInstance() {
        let instanceName = instanceSuffix == 0 ? baseName : "\(baseName) (\(instanceSuffix))"
        ownName = instanceName
        if let old = advertiser {
            old.delegate = nil
            old.stop()
        }

        let service = NetService(domain: domain,
                                 type: serviceType,
                                 name: instanceName,
                                 port: Int32(ownPort))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["id": Data(ownID.utf8)]))
        published = false
        service.publish()
        advertiser = service
        MobileLog.write("广播 \(instanceName) :\(ownPort)")
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

    func browse() {
        browser?.stop()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: serviceType, inDomain: domain)
        self.browser = browser
        lastActivity = Date()
        startHealthTimer()
        MobileLog.write("开始浏览对端")
    }

    /// 回到前台：系统已经把之前的广播收掉了，必须重新发布 + 重新浏览，
    /// 否则本机在别人的列表里会一直不出现（实测踩过）。
    func restart() {
        if advertiser != nil, ownPort > 0, !baseName.isEmpty {
            advertise(name: baseName, port: ownPort)
        }
        browse()
    }

    func stop() {
        healthTimer?.cancel()
        healthTimer = nil
        publishRetry?.cancel()
        publishRetry = nil
        advertiser?.stop()
        advertiser = nil
        browser?.stop()
        browser = nil
        resolving.removeAll()
        pendingRemovals.values.forEach { $0.cancel() }
        pendingRemovals.removeAll()
        resolveRetries.values.forEach { $0.cancel() }
        resolveRetries.removeAll()
    }

    /// 广播静默失败、或浏览线程被系统回收时，回调永远不会来。
    /// 看门狗只做幂等的自愈：没发布成功就重发，长时间没有回调就重启浏览。
    private func startHealthTimer() {
        guard healthTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.macdrop.mobile.bonjour.health")
        )
        timer.schedule(deadline: .now() + Self.healthInterval, repeating: Self.healthInterval)
        timer.setEventHandler { [weak self] in self?.checkHealth() }
        timer.resume()
        healthTimer = timer
    }

    private func checkHealth() {
        if advertiser != nil, !published {
            MobileLog.write("广播未上线，重新发布")
            DispatchQueue.main.async { [weak self] in
                self?.scheduleRepublish()
            }
        }
        if browser != nil, Date().timeIntervalSince(lastActivity) > Self.staleAfter {
            MobileLog.write("浏览超过 \(Int(Self.staleAfter)) 秒无回调，重启浏览")
            DispatchQueue.main.async { [weak self] in
                self?.browser?.stop()
                self?.browser = nil
                self?.browse()
            }
        }
    }

    private func touch() {
        lastActivity = Date()
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
        // 同一台设备换了地址（DHCP 续租/切网）或换了实例名：把指向同一地址的旧条目撤掉，
        // 否则列表里会出现两个它。先收集再删，边遍历边改字典是不安全的。
        var stale: [String] = []
        for (name, value) in byServiceName where name != serviceName && value.endpoint == peer.endpoint {
            stale.append(name)
        }
        if let previous = byServiceName[serviceName], previous.endpoint != peer.endpoint {
            stale.append(serviceName)
        }
        for name in stale {
            byServiceName.removeValue(forKey: name)
        }
        byServiceName[serviceName] = peer
        cancelPendingRemoval(serviceName: serviceName)
        rebuild()
        publish()
    }

    private func remove(serviceName: String) {
        pendingRemovals.removeValue(forKey: serviceName)?.cancel()
        resolveRetries.removeValue(forKey: serviceName)?.cancel()
        resolveAttempts.removeValue(forKey: serviceName)
        byServiceName.removeValue(forKey: serviceName)
        rebuild()
        publish()
    }

    /// 只移除消失的那一台设备，且给 6 秒宽限期
    private func scheduleRemoval(serviceName: String) {
        let work = DispatchWorkItem { [weak self] in
            self?.remove(serviceName: serviceName)
        }
        pendingRemovals.removeValue(forKey: serviceName)?.cancel()
        pendingRemovals[serviceName] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func cancelPendingRemoval(serviceName: String) {
        pendingRemovals.removeValue(forKey: serviceName)?.cancel()
    }

    /// 手动添加 / 扫描得到的对端，不会被 lost 事件清掉
    func addDirect(_ peer: Peer) {
        byServiceName["manual:\(peer.endpoint)"] = peer
        rebuild()
        publish()
    }

    private func rebuild() {
        peers = byServiceName.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func publish() {
        let snapshot = peers
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(snapshot)
        }
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
        for ip in localIPv4s() {
            let parts = ip.split(separator: ".").map(String.init)
            if parts.count == 4 { result.insert(parts[0...2].joined(separator: ".")) }
        }
        return result
    }

    /// 本机 IPv4 地址（不含 IPv6 与链路本地）
    private static func localIPv4s() -> [String] {
        var result: [String] = []
        for address in localAddresses() where !address.contains(":") && !address.hasPrefix("169.254.") {
            result.append(address)
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
        touch()
        guard !isSelf(service) else { return }
        MobileLog.write("发现对端：\(service.name)")
        cancelPendingRemoval(serviceName: service.name)
        service.delegate = self
        resolving.insert(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didRemove service: NetService,
                           moreComing: Bool) {
        touch()
        MobileLog.write("对端消失：\(service.name)")
        resolving.remove(service)
        scheduleRemoval(serviceName: service.name)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser,
                           didNotSearch errorDict: [String: NSNumber]) {
        MobileLog.write("浏览失败：\(errorDict)，稍后自动重试")
        lastActivity = .distantPast
    }
}

extension PeerBrowser: NetServiceDelegate {

    func netServiceDidPublish(_ sender: NetService) {
        touch()
        published = true
        publishFailures = 0
        MobileLog.write("广播已上线：\(sender.name) :\(sender.port)")
    }

    /// 本地网络权限被拒时，发布可能既不成功也不报错；必须留痕，否则无从排查
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        touch()
        published = false
        publishFailures += 1
        if publishFailures >= 2 {
            instanceSuffix += 1
            publishFailures = 0
            MobileLog.write("广播名「\(baseName)」被占用，改用「\(baseName) (\(instanceSuffix))」重试")
        }
        MobileLog.write("广播失败：\(errorDict)")
        scheduleRepublish()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        touch()
        resolving.remove(sender)
        resolveAttempts.removeValue(forKey: sender.name)
        let candidates = PeerBrowser.candidates(from: sender.addresses ?? [])
        guard let best = candidates.first else {
            MobileLog.write("解析地址失败：\(sender.name)")
            scheduleResolveRetry(sender)
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
                    alternatives: alternatives,
                    isPeerToPeer: best.ip.hasPrefix("169.254.")),
               serviceName: sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        touch()
        resolving.remove(sender)
        MobileLog.write("解析超时：\(sender.name) \(errorDict)")
        scheduleResolveRetry(sender)
    }

    /// Wi-Fi 拥挤时一次解析超时很常见，放弃就等于这台设备从此不再出现在列表里。
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
}
