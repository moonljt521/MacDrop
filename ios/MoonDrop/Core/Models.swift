import Foundation

struct Peer: Identifiable, Hashable {
    var id: String { "\(name)@\(host):\(port)" }
    var name: String
    var host: String
    var port: UInt16
    var isManual: Bool = false
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
