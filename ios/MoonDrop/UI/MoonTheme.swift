import SwiftUI
import UIKit

enum MoonTheme {
    static let canvas = dynamic(light: 0xF7F8FB, dark: 0x11141C)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x202631)
    static let surfaceMuted = dynamic(light: 0xEDF1FB, dark: 0x242E47)
    static let ink = dynamic(light: 0x233149, dark: 0xDCE5FA)
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x1B2740)

    static let textPrimary = dynamic(light: 0x202B40, dark: 0xEDF1FB)
    static let textSecondary = dynamic(light: 0x687284, dark: 0xA7B1C4)
    static let textTertiary = textSecondary
    static let divider = dynamic(light: 0xE2E7F0, dark: 0x303B50)

    static let primary = dynamic(light: 0x3E5BCA, dark: 0xA9BBFF)
    static let primaryStrong = dynamic(light: 0x254AB3, dark: 0xA4BAFF)
    static let primaryTint = dynamic(light: 0xEDF1FB, dark: 0x242E47)
    static let onPrimary = dynamic(light: 0xFFFFFF, dark: 0x101A33)

    static let success = dynamic(light: 0x227B65, dark: 0x7DD4B6)
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

struct MoonChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(MoonTheme.textTertiary)
            .accessibilityHidden(true)
    }
}

struct MoonEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(MoonTheme.textTertiary)
            Text(title)
                .font(MoonType.title)
                .foregroundStyle(MoonTheme.textPrimary)
                .padding(.top, 14)
            Text(message)
                .font(MoonType.meta)
                .foregroundStyle(MoonTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}

struct MoonPeerField: View {
    let peers: [Peer]
    /// 局域网扫描进行中：舞台亮起雷达光束
    var scanning: Bool = false
    let onSelect: (Peer) -> Void

    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var minimumFieldWidth: CGFloat = 300
    @ScaledMetric(relativeTo: .body) private var fieldHeight: CGFloat = 316

    var body: some View {
        Group {
            if peers.isEmpty {
                emptyField
            } else if usesList {
                peerList
            } else {
                ViewThatFits(in: .horizontal) {
                    constellation
                        .frame(minWidth: minimumFieldWidth)
                    peerList
                }
            }
        }
        .frame(maxWidth: .infinity)
        .transition(reduceMotion ? .identity : .opacity)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var usesList: Bool {
        if peers.count > 6 { return true }
        if dynamicTypeSize >= .xxxLarge { return true }
        if peers.count >= 6 && dynamicTypeSize >= .xLarge { return true }
        return peers.count >= 4 && dynamicTypeSize >= .xxLarge
    }

    private var isDense: Bool { peers.count >= 4 }

    private var constellation: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let peerWidth = peerWidth(for: width)
            ZStack(alignment: .topLeading) {
                MoonFieldDecoration(scanning: scanning)
                ForEach(Array(peers.enumerated()), id: \.element.endpoint) { index, peer in
                    let slot = slot(index, width: width, height: height)
                    MoonFieldPeerButton(peer: peer, isList: false,
                                        compact: isDense, singleLine: peers.count >= 6,
                                        onSelect: onSelect)
                        .frame(width: peerWidth)
                        .offset(x: slot.x - peerWidth / 2, y: slot.y)
                        .transition(arrivalTransition)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            // 扫描中新发现的设备弹入并落位，其余设备跟着让位
            .animation(arrivalAnimation, value: peers)
        }
        .frame(height: fieldHeight)
        .frame(minHeight: fieldHeight)
        .frame(maxWidth: max(430, minimumFieldWidth))
        .frame(maxWidth: .infinity)
    }

    /// 扫描中才给设备加浮现动效，平时设备增减保持安静
    private var arrivalTransition: AnyTransition {
        (scanning && !reduceMotion)
            ? .scale(scale: 0.72).combined(with: .opacity)
            : .identity
    }

    private var arrivalAnimation: Animation? {
        (scanning && !reduceMotion)
            ? .spring(response: 0.45, dampingFraction: 0.8)
            : nil
    }

    private func peerWidth(for width: CGFloat) -> CGFloat {
        if isDense { return width * 0.31 }
        switch peers.count {
        case 1: return width * 0.42
        case 2: return width * 0.34
        default: return (width - 24) / 3
        }
    }

    private func slot(_ index: Int, width: CGFloat, height: CGFloat) -> CGPoint {
        let top: CGFloat = isDense ? 8 : (peers.count == 3 ? 10 : 16)
        let lower = isDense ? (peers.count >= 6 ? 108 : 130) : height * 0.31
        let centers: [(CGFloat, CGFloat)] = {
            switch peers.count {
            case 1:
                return [(0.5, top)]
            case 2:
                return [(0.28, top), (0.72, top)]
            case 3:
                return [(0.5, top), (0.165, lower), (0.835, lower)]
            case 4:
                return [(0.27, top), (0.73, top), (0.165, lower), (0.835, lower)]
            case 5:
                return [(0.17, top), (0.5, top), (0.83, top), (0.24, lower), (0.76, lower)]
            default:
                return [(0.17, top), (0.5, top), (0.83, top),
                        (0.17, lower), (0.5, lower), (0.83, lower)]
            }
        }()
        let item = centers[min(index, centers.count - 1)]
        return CGPoint(x: width * item.0, y: item.1)
    }

    private var peerList: some View {
        VStack(spacing: 8) {
            ForEach(peers, id: \.endpoint) { peer in
                MoonFieldPeerButton(peer: peer, isList: true, onSelect: onSelect)
            }
            MoonLocalDevice()
                .padding(.top, 24)
        }
        .padding(.vertical, 16)
    }

    private var emptyField: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(scanning ? moonT("正在扫描局域网") : moonT("等待设备出现"))
                    .font(.title3.weight(.medium))
                    .foregroundStyle(MoonTheme.textPrimary)
                Text(scanning ? moonT("正在逐个探测同网段的设备") : moonT("在另一台设备上打开 MoonDrop"))
                    .font(MoonType.meta)
                    .foregroundStyle(MoonTheme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

            MoonFieldDecoration(scanning: scanning)
                .frame(height: 214)
        }
        .padding(.top, 24)
        .frame(minHeight: 340)
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
    }
}

private struct MoonFieldPeerButton: View {
    let peer: Peer
    let isList: Bool
    var compact: Bool = false
    var singleLine: Bool = false
    let onSelect: (Peer) -> Void

    @ObservedObject private var prefs = MoonPreferences.shared

    var body: some View {
        Button {
            onSelect(peer)
        } label: {
            if isList {
                HStack(alignment: .top, spacing: 16) {
                    glyph
                    labels
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .contentShape(Rectangle())
            } else {
                VStack(spacing: compact ? 6 : 8) {
                    glyph
                    labels
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(MoonPressStyle())
        .accessibilityLabel(moonTF("发送到 %@", peer.name))
        .accessibilityValue(connectionType)
    }

    private var glyph: some View {
        Image(systemName: "desktopcomputer")
            .font(.system(size: compact ? 27 : 32, weight: .regular))
            .foregroundStyle(MoonTheme.textPrimary)
            .frame(width: compact ? 56 : 68, height: compact ? 56 : 68)
            .background(MoonTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 20 : 24, style: .continuous))
            .accessibilityHidden(true)
    }

    private var labels: some View {
        VStack(alignment: isList ? .leading : .center, spacing: 4) {
            if isList {
                Text(peer.name)
                    .font(MoonType.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(peer.name)
                    .font(compact ? MoonType.label.weight(.medium) : MoonType.body.weight(.medium))
                    .lineLimit(singleLine ? 1 : 2)
            }
            Text(connectionType)
                .font(compact ? MoonType.label : MoonType.meta)
                .foregroundStyle(MoonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(MoonTheme.textPrimary)
        .multilineTextAlignment(isList ? .leading : .center)
    }

    private var connectionType: String {
        if peer.isPeerToPeer { return moonT("点对点直连") }
        // 扫描兜底发现的设备也是局域网直连，不该说成「手动连接」
        if peer.isManual && !peer.isScanned { return moonT("手动连接") }
        return moonT("局域网直连")
    }
}

private struct MoonLocalDevice: View {
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(MoonTheme.primary)
                .frame(width: 78, height: 78)
                .background(Circle().fill(MoonTheme.primaryTint))
                .overlay {
                    Circle()
                        .strokeBorder(MoonTheme.divider, lineWidth: 1 / displayScale)
                        .padding(-9)
                }
                .accessibilityHidden(true)
            Text(moonT("此设备"))
                .font(MoonType.meta)
                .foregroundStyle(MoonTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MoonFieldDecoration: View {
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .footnote) private var localLabelHeight: CGFloat = 16

    /// 扫描中：从「此设备」打出一道雷达光束
    let scanning: Bool

    var body: some View {
        GeometryReader { geometry in
            // 光束原点就是「此设备」的圆心：此处即雷达，设备场即目标区
            let origin = CGPoint(x: geometry.size.width / 2,
                                 y: geometry.size.height - localLabelHeight - 57)
            let radius = max(0, min(geometry.size.width / 2 - 8, origin.y - 8))
            ZStack {
                // These stationary arcs are decoration, not measured distances.
                Path { path in
                    for fraction in [CGFloat(1), 0.82] {
                        path.move(to: CGPoint(x: origin.x - radius * fraction, y: origin.y))
                        path.addArc(center: origin, radius: radius * fraction,
                                    startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                    }
                }
                .stroke(MoonTheme.divider, lineWidth: 1 / displayScale)
                .accessibilityHidden(true)

                Path { path in
                    path.addArc(center: origin, radius: radius * 0.58,
                                startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                }
                .stroke(MoonTheme.divider, style: StrokeStyle(lineWidth: 1 / displayScale, dash: [2, 7]))
                .accessibilityHidden(true)

                if scanning {
                    MoonRadarBeam(origin: origin,
                                  reach: max(geometry.size.width, geometry.size.height))
                        .clipped()
                }

                MoonLocalDevice()
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

/// 雷达节拍：舞台光束与按钮表盘共用同一个转速，看起来是同一个东西的两个尺寸。
enum MoonRadar {
    /// 转一圈要多久
    static let period: TimeInterval = 1.8
    /// 按绝对时间取角度：任意时刻接着转，不会因为重新扫描而跳相位
    static func angle(at date: Date) -> Double {
        let t = date.timeIntervalSinceReferenceDate
        return t.truncatingRemainder(dividingBy: period) / period * 360
    }
}

/// 雷达光束：从「此设备」发出的一束光，绕着本机匀速旋转。
///
/// 这是「正在搜寻」的状态信号，不声称任何百分比：扫多久它就转多久，
/// 扫描结束即消失。真实的结果由副标题的台数和逐个冒出来的设备来说。
private struct MoonRadarBeam: View {
    /// 光束原点：「此设备」的圆心
    let origin: CGPoint
    /// 光束能照到的最远距离
    let reach: CGFloat
    /// 光束张角
    private let spread: Double = 46

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                beam(angle: 250)
            } else {
                TimelineView(.animation) { timeline in
                    beam(angle: MoonRadar.angle(at: timeline.date))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func beam(angle: Double) -> some View {
        Canvas { ctx, _ in
            // 光束只照本机上方：把角度段夹到 180°–360°，转到身后的部分被「此设备」挡住
            let start = angle - spread / 2
            let end = angle + spread / 2
            var segments: [(Double, Double)] = []
            for shift in [0.0, 360.0, -360.0] {
                let lo = max(start + shift, 180)
                let hi = min(end + shift, 360)
                if hi > lo { segments.append((lo, hi)) }
            }

            let canvas = CGRect(x: origin.x - reach, y: origin.y - reach,
                                width: reach * 2, height: reach * 2)

            ctx.drawLayer { layer in
                for (lo, hi) in segments {
                    var cone = Path()
                    cone.move(to: origin)
                    cone.addArc(center: origin, radius: reach,
                                startAngle: .degrees(lo), endAngle: .degrees(hi), clockwise: false)
                    cone.closeSubpath()

                    // 角向：尾部透明 → 前沿最亮，像一束真的光扫过去
                    layer.fill(cone, with: .conicGradient(
                        Gradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: MoonTheme.primary.opacity(0.17), location: spread / 360),
                            .init(color: .clear, location: (spread + 6) / 360)
                        ]),
                        center: origin,
                        angle: .degrees(start)))
                }

                // 前沿亮线
                var head = end.truncatingRemainder(dividingBy: 360)
                if head < 0 { head += 360 }
                if head >= 180 {
                    var edge = Path()
                    edge.move(to: origin)
                    edge.addLine(to: CGPoint(x: origin.x + reach * cos(head * .pi / 180),
                                             y: origin.y + reach * sin(head * .pi / 180)))
                    layer.stroke(edge, with: .color(MoonTheme.primary.opacity(0.45)), lineWidth: 1.5)
                }

                // 压暗转到本机身后的部分，避免光扫到场地外的死角
                layer.blendMode = .destinationIn
                layer.fill(Path(canvas), with: .conicGradient(
                    Gradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.44),
                        .init(color: .black.opacity(0.04), location: 0.56),
                        .init(color: .black.opacity(0.04), location: 0.9),
                        .init(color: .black, location: 1)
                    ]),
                    center: origin,
                    angle: .degrees(180)))

                // 径向：离本机越远越淡，光束不会在场边切出一条硬边
                layer.blendMode = .destinationIn
                layer.fill(Path(canvas), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.85), location: 0.3),
                        .init(color: .black.opacity(0.28), location: 0.6),
                        .init(color: .clear, location: 0.88)
                    ]),
                    center: origin,
                    startRadius: 0,
                    endRadius: reach))
            }
        }
    }
}

struct MoonSendDock: View {
    let enabled: Bool
    let onFile: () -> Void
    let onAlbum: () -> Void

    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: 6))
            : AnyLayout(HStackLayout(spacing: 6))
        layout {
            Button(action: onFile) {
                dockLabel(moonT("选择文件"), symbol: "folder")
                    .foregroundStyle(enabled ? MoonTheme.onInk : MoonTheme.textSecondary)
                    .background(enabled ? MoonTheme.ink : MoonTheme.surfaceMuted)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityLabel(moonT("选择文件发送"))

            Button(action: onAlbum) {
                dockLabel(moonT("相册"), symbol: "photo.on.rectangle")
                    .foregroundStyle(enabled ? MoonTheme.textPrimary : MoonTheme.textSecondary)
            }
            .accessibilityLabel(moonT("从相册发送"))
        }
        .buttonStyle(MoonPressStyle())
        .disabled(!enabled)
        .padding(7)
        .background(MoonTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func dockLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(MoonType.button)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MoonTransferCard: View {

    enum Mode {
        case sending(progress: Double, detail: String, large: Bool)
        case receiving(progress: Double, detail: String)
        case finished(detail: String, isError: Bool)
    }

    let mode: Mode

    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .title) private var percentageSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var ringDiameter: CGFloat = 154

    var body: some View {
        VStack(spacing: 0) {
            ring

            Text(title)
                .font(MoonType.body.weight(.medium))
                .foregroundStyle(titleColor)
                .padding(.top, 18)

            Text(detail)
                .font(MoonType.meta)
                .foregroundStyle(MoonTheme.textSecondary)
                .padding(.top, 8)

            if let warning {
                Text(warning)
                    .font(MoonType.meta)
                    .foregroundStyle(MoonTheme.warningText)
                    .padding(.top, 14)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, minHeight: 330)
        .accessibilityElement(children: .combine)
        .transition(reduceMotion ? .identity : .opacity)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(MoonTheme.divider, lineWidth: 1 / displayScale)
                .accessibilityHidden(true)

            if let progress {
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.18), value: progress)
                    .accessibilityHidden(true)
            }

            if let percent {
                Text("\(percent)%")
                    .font(.system(size: percentageSize, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(MoonTheme.textPrimary)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: percentageSize, weight: .regular))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: ringDiameter)
    }

    private var symbol: String {
        switch mode {
        case .sending: return "paperplane"
        case .receiving: return "arrow.down"
        case .finished(_, let isError):
            return isError ? "exclamationmark" : "checkmark"
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
        case .sending: return moonT("正在发送")
        case .receiving: return moonT("正在接收")
        case .finished(let detail, let isError):
            if isError {
                return moonTextMatches(detail, key: "发送失败") ? moonT("发送失败") : moonT("操作失败")
            }
            if moonTextMatches(detail, key: "已发送") { return moonT("发送完成") }
            if moonTextMatches(detail, key: "已接收") { return moonT("接收完成") }
            return moonT("完成")
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
        progress.map { Int(($0 * 100).rounded()) }
    }

    private var progress: Double? {
        switch mode {
        case .sending(let progress, _, _), .receiving(let progress, _):
            // Render the supplied value, including decreases; never infer completion.
            return progress.isNaN ? 0 : min(max(progress, 0), 1)
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
            return large ? moonT("大文件传输中，请保持 MoonDrop 在前台；锁屏或切走会中断。") : nil
        case .receiving, .finished:
            return nil
        }
    }
}

// MARK: - 发送选项

struct SendOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = MoonPreferences.shared
    let peer: Peer
    let onSelect: (MoonSendAction) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(peer.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(MoonTheme.textPrimary)
                        Text(subtitle)
                            .font(MoonType.meta)
                            .foregroundStyle(MoonTheme.textSecondary)
                    }
                    MoonPrimaryButton(title: moonT("选择文件")) { onSelect(.file) }
                    Button {
                        onSelect(.album)
                    } label: {
                        Label(moonT("从相册发送"), systemImage: "photo.on.rectangle")
                            .font(MoonType.button)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .background(MoonTheme.canvas)
            .navigationTitle(moonT("发送到"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(moonT("取消")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var subtitle: String {
        let address = "\(peer.host):\(peer.port)"
        return peer.isPeerToPeer ? moonTF("点对点直连 · %@", address) : address
    }
}

// MARK: - 帮助

struct StorageHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var prefs = MoonPreferences.shared

    var body: some View {
        NavigationStack {
            List {
                Section(moonT("收到的文件放在哪")) {
                    Text(moonT("普通文件保存在「文件」App → 我的 iPhone → MoonDrop → Received。开启「自动存入相册」后，图片和视频写入系统相册；同一个文件只会存一次，不会重复。"))
                }

                Section(moonT("看不见设备怎么办")) {
                    Text(moonT("确认双方都打开了 MoonDrop，并连在同一个 Wi-Fi。附近的 Apple 设备即使连着别的网络，也会以「点对点」出现；Android 设备必须同一 Wi-Fi。\n\n仍然看不见就扫描局域网，或手动填写对方的 IP 和端口 52345。"))
                }

                Section(moonT("后台接收")) {
                    Text(moonT("接收过程中请保持 MoonDrop 在前台，锁屏或长时间切到后台可能中断传输。iPhone 切到后台会停止广播，回到前台会自动恢复。"))
                }

                Section(moonT("关于")) {
                    Text(moonTF("MoonDrop %@ · 局域网直连，不经过云端。", version))
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MoonTheme.canvas)
            .navigationTitle(moonT("存储位置与常见问题"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(moonT("完成")) { dismiss() }
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
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent(moonT("本机名称"), value: model.deviceName)
                    LabeledContent(moonT("监听端口"),
                                   value: model.listenPort > 0 ? String(model.listenPort) : moonT("启动中"))
                    LabeledContent(moonT("局域网地址"), value: addressText)
                    LabeledContent(moonT("广播状态"), value: advertiseText)
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
                        Label(copied ? moonT("已复制") : moonT("复制地址"), systemImage: "doc.on.doc")
                    }
                    .disabled(model.localAddresses.isEmpty)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MoonTheme.canvas)
            .navigationTitle(moonT("连接详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(moonT("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var addressText: String {
        let addresses = model.localAddresses
        return addresses.isEmpty ? moonT("未连接 Wi-Fi") : addresses.joined(separator: ", ")
    }

    private var advertiseText: String {
        if model.listenPort <= 0 { return moonT("接收服务启动中") }
        return model.isAdvertiseLive ? moonT("已上线") : moonT("未确认")
    }

    private var explanation: String {
        if model.listenPort <= 0 {
            return moonT("接收服务还在启动，请稍等。")
        }
        if model.localAddresses.isEmpty {
            return moonT("未取得局域网地址，请确认已连接 Wi-Fi。")
        }
        if !model.isAdvertiseLive {
            return moonT("广播未确认。请在「设置 → 隐私与安全性 → 本地网络」允许 MoonDrop，或改用扫描 / 手动填写 IP。")
        }
        return moonT("其他设备可以在同一 Wi-Fi 下直接看到本机。")
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

enum MoonType {
    static let hero = Font.headline
    static let title = Font.body
    static let body = Font.callout
    static let meta = Font.footnote
    static let label = Font.caption
    static let numeric = Font.title.weight(.semibold)
    static let button = Font.callout.weight(.semibold)
}

enum MoonTrack {
    static let tight: CGFloat = -0.4
    static let wide: CGFloat = 0
}

struct MoonPanel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MoonTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct MoonHairline: View {
    @Environment(\.displayScale) private var displayScale
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(MoonTheme.divider)
            .frame(height: 1 / displayScale)
            .padding(.leading, inset)
            .accessibilityHidden(true)
    }
}

struct MoonSectionLabel<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(MoonTheme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
    }
}

extension MoonSectionLabel where Accessory == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

struct MoonListRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var iconTint: Color = MoonTheme.textSecondary
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 24, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MoonType.title.weight(.medium))
                    .foregroundStyle(MoonTheme.textPrimary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(MoonType.meta)
                        .foregroundStyle(MoonTheme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.vertical, 14)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }
}

extension MoonListRow where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil,
         iconTint: Color = MoonTheme.textSecondary) {
        self.init(symbol: symbol, title: title, subtitle: subtitle, iconTint: iconTint) {
            EmptyView()
        }
    }
}

struct MoonPrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MoonType.button)
                .foregroundStyle(enabled ? MoonTheme.onPrimary : MoonTheme.textTertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(enabled ? MoonTheme.primary : MoonTheme.surfaceMuted)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(MoonPressStyle())
        .disabled(!enabled)
    }
}

struct MoonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// 次级文字动作：无底、居中、安静。
struct MoonTextAction: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(MoonType.body.weight(.medium))
                .foregroundStyle(enabled ? MoonTheme.textSecondary : MoonTheme.textTertiary)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct MoonStatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

/// 重新扫描按钮上的雷达表盘。
///
/// 和舞台光束同一个转速、同一个方向：它表示「正在搜寻」，不声称任何百分比。
/// 扫多久它就转多久，扫描结束就换回普通图标。
struct MoonScanGlyph: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let diameter: CGFloat = 15

    var body: some View {
        Group {
            if reduceMotion {
                dial(angle: 250)
            } else {
                TimelineView(.animation) { timeline in
                    dial(angle: MoonRadar.angle(at: timeline.date))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func dial(angle: Double) -> some View {
        ZStack {
            Circle()
                .strokeBorder(MoonTheme.divider, lineWidth: 1 / displayScale)
                .frame(width: diameter, height: diameter)

            sweep
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(angle))
        }
        .frame(width: diameter + 2, height: diameter + 2)
    }

    private var sweep: some View {
        ZStack {
            // 光束：表盘正上方向左铺开的一瓣
            MoonScanBeam()
                .fill(MoonTheme.primary.opacity(0.18))
            // 指针：从圆心指向正上方
            Rectangle()
                .fill(MoonTheme.primary)
                .frame(width: 1.5, height: diameter / 2)
                .offset(y: -diameter / 4)
        }
    }
}

/// 雷达光束：正上方（-90°）逆时针铺开的一瓣
private struct MoonScanBeam: Shape {
    let angle: Double = 58

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.move(to: center)
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(-90 - angle), endAngle: .degrees(-90), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// 圆形图标按钮。中性色，不抢戏。
struct MoonCircleButton: View {
    let symbol: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MoonTheme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
