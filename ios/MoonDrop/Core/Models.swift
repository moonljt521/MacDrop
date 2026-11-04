import Foundation

struct Peer: Identifiable, Hashable {
    var id: String { "\(name)@\(host):\(port)" }
    var name: String
    var host: String
    var port: UInt16
    var isManual: Bool = false
    /// 同一台设备的其它可用地址：首选地址连不通时依次尝试
    var alternatives: [String] = []
    /// 通过点对点（AWDL）连上：对方不在当前 Wi-Fi，而是在附近用直连通道
    var isPeerToPeer: Bool = false

    /// 去重用的地址键：设备改名后 Bonjour 实例名会变，按它才能认出是同一台
    var endpoint: String { "\(host):\(port)" }
}

/// 一次发送的记录，用于「已发送」列表
struct SentRecord: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var names: [String]
    var target: String
    var size: Int64
    var date: Date
}

struct OutgoingFile {
    var url: URL
    var relativePath: String
    var size: Int64
}

struct ReceivedItem: Identifiable, Hashable {
    var id: String { url.path }
    var url: URL
    var name: String
    var isDirectory: Bool
    var size: Int64
    var modified: Date
}

enum MobileLog {
    static func write(_ message: String) {
        NSLog("[MoonDropMobile] %@", message)
    }
}
