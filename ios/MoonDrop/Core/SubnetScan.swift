import Foundation

/// 不依赖 mDNS 的兜底发现：扫描本机所在网段的 52345 端口。
///
/// 为什么需要：部分路由器（尤其企业/酒店 Wi-Fi、屏蔽组播的 AP）会让 Bonjour 的广播和查询
/// 全都出不去，各端「在线且在同一 Wi-Fi」却互相看不见。单播 TCP 通常仍然放行，
/// 于是直接 ping 一遍同网段地址就能把人找回来。
/// 局限：只能找到监听默认端口 52345 的设备；跨网段或开了客户端隔离的网络仍然无效。
///
/// 扫描是流式的：每探测完一个地址就上报一次真实进度，命中哪台就立刻回调哪台。
/// 这样界面可以边扫边显示，而不是等最长 12 秒后一次性砸下一堆结果。
enum SubnetScan {

    struct Found: Equatable {
        let host: String
        let port: UInt16
        let name: String
    }

    /// 扫描过程中的真实状态。没有任何计时器成分：probed 是真的探测过多少个地址。
    struct Progress: Equatable {
        /// 已经探测过的地址数
        var probed: Int
        /// 本次扫描的候选地址总数
        var total: Int
        /// 累计命中的设备
        var found: [Found]
    }

    private static let defaultPort: UInt16 = 52345
    /// 单次扫描的硬时限：客户端隔离的网络里每个地址都要等到超时，不能让人等下去
    private static let deadline: TimeInterval = 12
    /// 普通进度上报的最小间隔：探测很快时不必每个地址都通知界面
    fileprivate static let reportInterval: TimeInterval = 0.08

    /// 后台执行，progress 与 completion 都在主线程回调。
    /// progress.found 是累计结果，每命中一台就多一个；completion 给出最终状态。
    /// 撞到硬时限而提前收工时，completion.probed 会小于 total，进度不会假装跑满。
    static func run(onProgress: @escaping @MainActor (Progress) -> Void,
                    completion: @escaping @MainActor (Progress) -> Void) {
        let candidates = candidateHosts()
        guard !candidates.isEmpty else {
            MobileLog.write("局域网扫描跳过：没有可用的局域网地址")
            DispatchQueue.main.async { completion(Progress(probed: 0, total: 0, found: [])) }
            return
        }
        let bucketCount = min(32, candidates.count)
        let group = DispatchGroup()
        let state = ScanState(total: candidates.count, onProgress: onProgress)
        let started = Date()

        for bucket in 0..<bucketCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                var index = bucket
                while index < candidates.count {
                    if Date().timeIntervalSince(started) > deadline { break }
                    let hit = probe(candidates[index])
                    state.record(hit: hit)
                    index += bucketCount
                }
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.global()) {
            let snapshot = state.snapshot()
            MobileLog.write("局域网扫描完成：探测 \(snapshot.probed)/\(snapshot.total) 个地址，命中 \(snapshot.found.count) 台")
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// 本机各网卡所在 /24 段的 .1–.254（排除本机自己）
    private static func candidateHosts() -> [String] {
        let local = localIPv4s()
        var hosts = Set<String>()
        for ip in local {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { continue }
            for last in 1...254 {
                let candidate = "\(parts[0]).\(parts[1]).\(parts[2]).\(last)"
                if local.contains(candidate) { continue }
                hosts.insert(candidate)
            }
        }
        return hosts.sorted()
    }

    private static func probe(_ host: String) -> Found? {
        guard let url = URL(string: "http://\(host):\(defaultPort)/macdrop/ping") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.0
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
        _ = done.wait(timeout: .now() + 1.5)
        return result
    }

    /// 本机局域网 IPv4 地址，用于 UI 自查与扫描排除自己
    static func localIPv4s() -> [String] {
        var result = [String]()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return result }
        defer { freeifaddrs(pointer) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.isEmpty || ip.hasPrefix("127.") { continue }
            result.append(ip)
        }
        return result
    }
}

/// 扫描过程中的共享状态：跨线程累积探测计数与命中结果。
private final class ScanState {

    private let lock = NSLock()
    private var probed = 0
    private var found: [SubnetScan.Found] = []
    private var lastReport = Date.distantPast
    private let total: Int
    private let onProgress: @MainActor (SubnetScan.Progress) -> Void

    init(total: Int, onProgress: @escaping @MainActor (SubnetScan.Progress) -> Void) {
        self.total = total
        self.onProgress = onProgress
    }

    /// 记录一次探测结果。命中立刻上报，普通进度按间隔节流，避免界面被刷屏。
    func record(hit: SubnetScan.Found?) {
        lock.lock()
        probed += 1
        if let hit { found.append(hit) }
        let now = Date()
        let isHit = hit != nil
        let shouldReport = isHit || now.timeIntervalSince(lastReport) >= SubnetScan.reportInterval
        if shouldReport { lastReport = now }
        let snapshot = SubnetScan.Progress(probed: probed, total: total, found: found)
        lock.unlock()

        guard shouldReport else { return }
        DispatchQueue.main.async { [onProgress] in onProgress(snapshot) }
    }

    func snapshot() -> SubnetScan.Progress {
        lock.lock()
        defer { lock.unlock() }
        return SubnetScan.Progress(probed: probed, total: total, found: found)
    }
}
