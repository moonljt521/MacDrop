import Foundation
import UIKit
import CryptoKit

/// 剪贴板文本捕获：进入 App 时把剪贴板里的纯文本存成 txt，排进「待发送」队列。
///
/// iOS 16 起读取 UIPasteboard 会弹系统的「允许粘贴？」提示，用户同意之前
/// 读到的永远是空。所以分两步：先用 hasStrings 无提示地确认剪贴板里确实有
/// 文本，再真正读取；读不到就交给上层稍后重试，等用户点完「允许粘贴」。
enum ClipboardCapture {

    enum Read {
        /// 剪贴板里没有可用的文本
        case empty
        /// 有文本但读不出来：系统还没放行粘贴
        case denied
        case text(String)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func read() -> Read {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasStrings else { return .empty }
        guard let text = pasteboard.string else { return .denied }
        // 有字符串却读到空串：系统还没放行粘贴（此时会弹「允许粘贴？」），
        // 用户点完允许后下一次读取就能拿到内容，所以这里按「还没拿到」处理。
        if text.isEmpty { return .denied }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        return .text(text)
    }

    /// 文本指纹：同一段文本不该被反复存成多个文件
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 剪贴板生成的临时文件放在 Application Support，不进 Documents，
    /// 用户的「文件」App 里看不到这些中间产物。
    static var directory: URL {
        let url = ConfigSupport.supportDir.appendingPathComponent("Clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 把文本写成 txt，返回文件 URL
    static func writeTextFile(_ text: String, prefix: String) -> URL? {
        let name = "\(prefix)-\(stampFormatter.string(from: Date())).txt"
        let url = directory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            MobileLog.write("写入剪贴板文件失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 清掉上次没发出去的残留文件
    static func cleanup() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
        // 早期调试版本留下的探针文件，顺手清掉
        try? fm.removeItem(at: ConfigSupport.supportDir.appendingPathComponent("probe.txt"))
    }
}
