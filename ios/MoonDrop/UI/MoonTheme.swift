import SwiftUI
import UIKit

/// MoonDrop 移动端设计令牌，来源见仓库根目录 DESIGN.md。
/// 浅色/深色跟随系统外观，不提供应用内开关。
enum MoonTheme {

    // MARK: - Colors

    static let canvas = dynamic(light: 0xF7F9FC, dark: 0x0B0F14)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x141A22)
    static let surfaceMuted = dynamic(light: 0xF1F5F9, dark: 0x1B232D)
    static let textPrimary = dynamic(light: 0x0F172A, dark: 0xE8EDF5)
    static let textSecondary = dynamic(light: 0x64748B, dark: 0x9AA7B8)
    static let textTertiary = dynamic(light: 0x94A3B8, dark: 0x6B7A8C)
    static let divider = dynamic(light: 0xEDF1F6, dark: 0x242D39)

    static let primary = dynamic(light: 0x2C6BFF, dark: 0x6E9BFF)
    static let primaryStrong = dynamic(light: 0x1E56D6, dark: 0xA8C3FF)
    static let primaryTint = dynamic(light: 0xEAF0FF, dark: 0x1A2740)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x06122B)

    static let success = dynamic(light: 0x12B76A, dark: 0x3DD68C)
    static let successText = dynamic(light: 0x067647, dark: 0x6EE7B7)
    static let successTint = dynamic(light: 0xE7F8F0, dark: 0x102A20)

    static let warning = dynamic(light: 0xF79009, dark: 0xFDB022)
    static let warningText = dynamic(light: 0xB54708, dark: 0xFEC84B)
    static let warningTint = dynamic(light: 0xFFF4E5, dark: 0x2A210F)

    static let danger = dynamic(light: 0xEF4444, dark: 0xF97066)
    static let dangerText = dynamic(light: 0xB42318, dark: 0xFDA29B)
    static let dangerTint = dynamic(light: 0xFEF3F2, dark: 0x2A1512)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum MoonSendAction {
    case file
    case album
}

/// 40pt 圆角图标底，品牌蓝只在这里和主按钮上出现。
struct MoonIconTile: View {
    let symbol: String
    var size: CGFloat = 40
    var tint: Color = MoonTheme.primaryStrong
    var background: Color = MoonTheme.primaryTint

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(background)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(tint)
            )
            .accessibilityHidden(true)
    }
}

/// 状态始终「圆点 + 文字」，不单靠颜色传达。
struct MoonStatusPill: View {
    let text: String
    let textColor: Color
    let dotColor: Color
    var background: Color = MoonTheme.surfaceMuted

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(background))
    }
}

struct MoonChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(MoonTheme.textTertiary)
            .accessibilityHidden(true)
    }
}

struct MoonPeerToPeerBadge: View {
    var body: some View {
        Text("点对点")
            .font(.caption2.weight(.medium))
            .foregroundStyle(MoonTheme.warningText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MoonTheme.warningTint)
            )
    }
}

struct MoonDeviceRow: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 12) {
            MoonIconTile(symbol: peer.isManual ? "link" : "desktopcomputer")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(peer.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MoonTheme.textPrimary)
                        .lineLimit(1)
                    if peer.isPeerToPeer {
                        MoonPeerToPeerBadge()
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(MoonTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            MoonChevron()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("点按选择文件或从相册发送")
    }

    private var subtitle: String {
        let address = "\(peer.host):\(peer.port)"
        if peer.isPeerToPeer {
            return "点对点直连 · \(address)"
        }
        return peer.isManual ? "手动添加 · \(address)" : address
    }
}

struct MoonEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            MoonIconTile(symbol: symbol, size: 44)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(MoonTheme.textPrimary)
                .padding(.top, 4)
            Text(message)
                .font(.caption)
                .foregroundStyle(MoonTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

struct MoonTransferCard: View {

    enum Mode {
        case sending(progress: Double, detail: String, large: Bool)
        case receiving(progress: Double, detail: String)
        case finished(detail: String, isError: Bool)
    }

    let mode: Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let percent {
                    Text("\(percent)%")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(MoonTheme.primaryStrong)
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .tint(MoonTheme.primary)
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(MoonTheme.textSecondary)
                .lineLimit(2)

            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(MoonTheme.warningText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch mode {
        case .sending: return "paperplane"
        case .receiving: return "arrow.down.circle"
        case .finished(_, let isError):
            return isError ? "exclamationmark.circle" : "checkmark.circle"
        }
    }

    private var accent: Color {
        switch mode {
        case .sending, .receiving: return MoonTheme.primary
        case .finished(_, let isError):
            return isError ? MoonTheme.danger : MoonTheme.success
        }
    }

    private var title: String {
        switch mode {
        case .sending: return "正在发送"
        case .receiving: return "正在接收"
        case .finished(let detail, let isError):
            if detail.hasPrefix("已发送") { return "发送完成" }
            if detail.hasPrefix("发送失败") { return "发送失败" }
            if detail.hasPrefix("已接收") { return "接收完成" }
            return isError ? "操作失败" : "完成"
        }
    }

    private var titleColor: Color {
        switch mode {
        case .sending, .receiving: return MoonTheme.textSecondary
        case .finished(_, let isError):
            return isError ? MoonTheme.dangerText : MoonTheme.successText
        }
    }

    private var percent: Int? {
        switch mode {
        case .sending(let progress, _, _), .receiving(let progress, _):
            return Int((progress * 100).rounded())
        case .finished:
            return nil
        }
    }

    private var progress: Double? {
        switch mode {
        case .sending(let progress, _, _), .receiving(let progress, _):
            return progress
        case .finished:
            return nil
        }
    }

    private var detail: String {
        switch mode {
        case .sending(_, let detail, _): return detail
        case .receiving(_, let detail): return detail
        case .finished(let detail, _): return detail
        }
    }

    private var warning: String? {
        switch mode {
        case .sending(_, _, let large):
            return large ? "大文件传输中，请保持 MoonDrop 在前台；锁屏或切走会中断。" : nil
        case .receiving, .finished:
            return nil
        }
    }
}

// MARK: - 发送选项

struct SendOptionsSheet: View {
    let peer: Peer
    let onSelect: (MoonSendAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("发送到 \(peer.name)")
                    .font(.headline)
                    .foregroundStyle(MoonTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(MoonTheme.textSecondary)
            }

            Button {
                onSelect(.file)
            } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MoonTheme.onPrimary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {
                onSelect(.album)
            } label: {
                Label("从相册发送", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 12)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
    }

    private var subtitle: String {
        let address = "\(peer.host):\(peer.port)"
        return peer.isPeerToPeer ? "点对点直连 · \(address)" : address
    }
}

// MARK: - 帮助

struct StorageHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("收到的文件放在哪") {
                    Text("普通文件保存在「文件」App → 我的 iPhone → MoonDrop → Received。开启「自动存入相册」后，图片和视频写入系统相册；同一个文件只会存一次，不会重复。")
                }

                Section("看不见设备怎么办") {
                    Text("确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。附近的 Apple 设备即使连着别的网络，也会以「点对点」出现；Android 设备必须同一 Wi-Fi。\n\n仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。")
                }

                Section("后台接收") {
                    Text("接收过程中请保持 MoonDrop 在前台，锁屏或长时间切到后台可能中断传输。iPhone 切到后台会停止广播，回到前台会自动恢复。")
                }

                Section("关于") {
                    Text("MoonDrop \(version) · 局域网直连，不经过云端。")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MoonTheme.canvas)
            .navigationTitle("存储位置与常见问题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

struct ConnectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("本机名称", value: model.deviceName)
                    LabeledContent("监听端口",
                                   value: model.listenPort > 0 ? String(model.listenPort) : "启动中")
                    LabeledContent("局域网地址", value: addressText)
                    LabeledContent("广播状态", value: advertiseText)
                }

                Section {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(MoonTheme.textSecondary)
                }

                Section {
                    Button {
                        copyAddress()
                    } label: {
                        Label(copied ? "已复制" : "复制地址", systemImage: "doc.on.doc")
                    }
                    .disabled(model.localAddresses.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MoonTheme.canvas)
            .navigationTitle("连接详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var addressText: String {
        let addresses = model.localAddresses
        return addresses.isEmpty ? "未连接 Wi-Fi" : addresses.joined(separator: ", ")
    }

    private var advertiseText: String {
        if model.listenPort <= 0 { return "接收服务启动中" }
        return model.isAdvertiseLive ? "已上线" : "未确认"
    }

    private var explanation: String {
        if model.listenPort <= 0 {
            return "接收服务还在启动，请稍等。"
        }
        if model.localAddresses.isEmpty {
            return "未取得局域网地址，请确认已连接 Wi-Fi。"
        }
        if !model.isAdvertiseLive {
            return "广播未确认。请在「设置 → 隐私与安全性 → 本地网络」允许 MoonDrop，或改用扫描 / 手动填写 IP。"
        }
        return "其他设备可以在同一 Wi-Fi 下直接看到本机。"
    }

    private func copyAddress() {
        guard let address = model.localAddresses.first else { return }
        let port = model.listenPort > 0 ? String(model.listenPort) : "52345"
        UIPasteboard.general.string = "\(address):\(port)"
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
