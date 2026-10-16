import Foundation

/// 用户可配置项，整体以 JSON 存在 UserDefaults 里
struct Settings: Codable, Equatable {
    struct ManualPeer: Codable, Equatable {
        var host: String
        var port: UInt16
        var label: String

        var id: String { "\(host):\(port)" }
    }

    var deviceName: String
    var downloadDir: String
    var port: UInt16
    var autoAccept: Bool
    var manualPeers: [ManualPeer]

    static func makeDefault() -> Settings {
        let home = NSHomeDirectory()
        return Settings(
            deviceName: Host.current().localizedName ?? "Mac",
            downloadDir: (home as NSString).appendingPathComponent("Downloads/来自另一台Mac"),
            port: 52345,
            autoAccept: true,
            manualPeers: []
        )
    }
}

final class Config {
    static let shared = Config()

    private let defaults: UserDefaults
    private let key = "com.macdrop.settings.v1"
    private let lock = NSLock()
    private var cached: Settings

    private init() {
        defaults = .standard

        // 测试/多实例支持：环境变量优先，避免互相覆盖
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MACDROP_RECV_DIR"], !dir.isEmpty {
            var s = Settings.makeDefault()
            s.downloadDir = dir
            if let p = env["MACDROP_PORT"], let pv = UInt16(p) { s.port = pv }
            if let n = env["MACDROP_NAME"], !n.isEmpty { s.deviceName = n }
            cached = s
            return
        }

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            cached = decoded
        } else {
            cached = Settings.makeDefault()
        }
    }

    var current: Settings { lock.withLock { cached } }

    @discardableResult
    func update(_ block: (inout Settings) -> Void) -> Settings {
        lock.lock()
        defer { lock.unlock() }
        var s = cached
        block(&s)
        cached = s
        if let data = try? JSONEncoder().encode(s) {
            defaults.set(data, forKey: key)
        }
        return s
    }

    var deviceName: String { current.deviceName }

    var port: UInt16 { current.port }

    var downloadDir: String { current.downloadDir }

    var downloadURL: URL {
        URL(fileURLWithPath: (current.downloadDir as NSString).expandingTildeInPath,
            isDirectory: true)
    }

    func ensureDownloadDir() throws {
        try FileManager.default.createDirectory(at: downloadURL,
                                                withIntermediateDirectories: true)
    }

    // MARK: - 运行时数据目录

    /// App 的运行时数据根目录：~/Library/Application Support/MacDrop/
    ///
    /// 刻意不放项目目录，也不放 Caches：
    ///   - 不放项目目录 → 拷贝 .app 给别的 Mac 时不会带上这些
    ///   - 不放 Caches    → 系统会定期清理 Caches，传输日志容易被莫名删掉
    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MacDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 传输暂存区：先写这里，全部传完才搬到接收目录
    static var stagingDir: URL {
        let url = supportDir.appendingPathComponent(".staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 日志目录
    static var logDir: URL {
        let url = supportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 传输日志文件
    static var logFile: URL {
        logDir.appendingPathComponent("transfer.log")
    }
}