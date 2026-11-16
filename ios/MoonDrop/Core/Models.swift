import Foundation

struct Peer: Identifiable, Hashable {
    var id: String { "\(name)@\(host):\(port)" }
    var name: String
    var host: String
    var port: UInt16
    var isManual: Bool = false
    /// 通过局域网扫描兜底发现的设备：它同样是局域网直连，只是 Bonjour 没报上来
    var isScanned: Bool = false
    /// 同一台设备的其它可用地址：首选地址连不通时依次尝试
    var alternatives: [String] = []
    /// 通过点对点（AWDL）连上：对方不在当前 Wi-Fi，而是在附近用直连通道
    var isPeerToPeer: Bool = false
    /// 对方自己上报的设备类型（mac / phone / pad），不靠名字猜
    var deviceType: String = ""

    /// 去重用的地址键：设备改名后 Bonjour 实例名会变，按它才能认出是同一台
    var endpoint: String { "\(host):\(port)" }
}

/// 设备类型：由对方自己上报（Bonjour TXT 与 /macdrop/ping 都带 type），
/// 不从设备名推断——名字是用户随便改的，推断出来的类型只会误导人。
enum PeerKind {
    static let mac = "mac"
    static let phone = "phone"
    static let pad = "pad"

    /// 对应形状的 SF Symbol
    static func symbol(for type: String) -> String {
        switch type {
        case phone: return "iphone"
        case pad: return "ipad"
        default: return "desktopcomputer"
        }
    }

    /// 无障碍朗读用的类型名；认不出来就返回空
    static func label(for type: String) -> String {
        switch type {
        case phone: return moonT("手机")
        case pad: return moonT("平板")
        case mac: return moonT("电脑")
        default: return ""
        }
    }
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
