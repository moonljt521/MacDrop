import AppKit

/// 悬浮接收区：拖放目标 + 传输进度显示。
///
/// 平时是圆形小浮窗（64×64，只显示一个图标，尽量不挡东西）；
/// 文件拖进来时自动展开到完整尺寸（300×132）显示提示和进度，
/// 拖离或传完后（结果展示 3 秒）自动收回圆形。
///
/// 观感目标是「安静、通透、不描边」：
///   1. 纯毛玻璃底（NSVisualEffectView，behindWindow + popover 材质），
///      不加任何外描边，形状全靠玻璃边缘和系统投影勾勒；
///   2. 顶部一道极淡的白色光泽，给玻璃一点纵深；
///   3. 拖入时只做「变亮 + 图标弹性放大」，不用任何彩色描边/色块；
///   4. 展开/收起时窗口 frame 与圆角同步做 0.22s 平滑形变，不是硬切；
///   5. 进度条自绘圆角胶囊，替代观感偏工业的 NSProgressIndicator；
///   6. 多台 Mac 在线时拖入后先弹出设备列表点选目标（只有一台则直接发送）。
///
/// 关于能力边界（很重要）：
/// macOS 的跨机器拖放事件由系统 sharingd 在系统层广播，第三方 App 无法自行发起。
/// 因此这个窗口有两种工作方式：
///   A. 同机拖放  → 一定可用：把文件拖进来，送到对端 Mac
///   B. 跨机拖放  → 取决于系统 AWDL 是否广播；若系统原生拖放失效，本窗口同样收不到
/// 通道 C（右键菜单「拷贝到…」）不依赖任何拖放，始终可用。
final class DropPanel: NSObject {

    private var panel: NSPanel!
    private var container: NSView!
    private var glass: NSVisualEffectView!
    private var sheenOverlay: NSView!
    private var hoverOverlay: NSView!
    private var dropView: DropView!
    private var iconHolder: NSView!
    private var iconView: NSImageView!
    private var statusLabel: NSTextField!
    private var deviceLabel: NSTextField!
    private var progressBar: RoundedProgressBar!

    private var peers: [Peer] = []

    /// 多设备选择器状态
    private var pickerMode = false
    private var pendingURLs: [URL] = []
    private var pickerRows: [DeviceRow] = []
    private var pickerCancelRow: DeviceRow?
    private var clickMonitor: Any?
    /// 面板当前尺寸（收起圆形 / 展开 / 选择器三种高度）
    private var currentSize: NSSize!

    /// 展开尺寸（完整形态）与收起尺寸（圆形小浮窗）
    private static let expandedSize = NSSize(width: 300, height: 132)
    private static let collapsedSize = NSSize(width: 64, height: 64)
    private static let expandedRadius: CGFloat = 16
    private static let morphDuration: TimeInterval = 0.22
    /// 设备列表最多显示台数（再多的场景极少，超出只显示前几台）
    private static let maxPickerRows = 4

    private var isExpanded = false
    private var isBusy = false          // 传输中/结果展示中，期间不收回
    private var isDragHovering = false  // 有拖拽悬停
    /// 忙碌代际：新的拖放/进度会作废旧的"3 秒后收起"定时器
    private var busyGeneration = 0
    /// 面板原本隐藏、因为收/发进度被临时唤出：结束后重新隐藏
    private var autoShownForTransfer = false
    private var pendingCollapse: DispatchWorkItem?

    static let shared = DropPanel()

    var onSend: (([URL], Peer) -> Void)?
    var onReceived: ((URL) -> Void)?

    // MARK: - 生命周期

    func build(deviceName: String) {
        let rect = NSRect(origin: .zero, size: Self.collapsedSize)
        panel = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.title = "MacDrop"
        // 固定深色外观：烟熏玻璃 + 白图标，在任何壁纸上都干净利落
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.layer?.cornerRadius = Self.collapsedSize.width / 2

        glass = NSVisualEffectView(frame: rect)
        glass.autoresizingMask = [.width, .height]
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active

        // 顶部一道极淡的白色光泽，给玻璃一点纵深
        sheenOverlay = NSView(frame: rect)
        sheenOverlay.autoresizingMask = [.width, .height]
        sheenOverlay.wantsLayer = true
        let sheen = CAGradientLayer()
        sheen.colors = [NSColor.white.withAlphaComponent(0.10).cgColor,
                        NSColor.white.withAlphaComponent(0.0).cgColor]
        sheen.locations = [0.0, 0.6]
        sheen.startPoint = CGPoint(x: 0.5, y: 1.0)
        sheen.endPoint = CGPoint(x: 0.5, y: 0.25)
        sheenOverlay.layer = sheen

        // 悬停时整体变亮（中性白，不用彩色）
        hoverOverlay = NSView(frame: rect)
        hoverOverlay.autoresizingMask = [.width, .height]
        hoverOverlay.wantsLayer = true
        hoverOverlay.layer?.backgroundColor =
            NSColor.white.withAlphaComponent(0.12).cgColor
        hoverOverlay.alphaValue = 0

        deviceLabel = NSTextField(labelWithString: deviceName)
        deviceLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        deviceLabel.textColor = .secondaryLabelColor
        deviceLabel.alignment = .center
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.autoresizingMask = [.width, .minYMargin]
        deviceLabel.alphaValue = 0

        statusLabel = NSTextField(labelWithString: "把文件拖到这里")
        statusLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.autoresizingMask = [.width, .minYMargin]
        statusLabel.alphaValue = 0

        progressBar = RoundedProgressBar(frame: .zero)
        progressBar.isHidden = true
        progressBar.autoresizingMask = [.width, .minYMargin]

        iconHolder = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        iconHolder.wantsLayer = true
        iconHolder.alphaValue = 1

        iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.92)
        if let symbol = NSImage(systemSymbolName: "arrow.down.to.line",
                                accessibilityDescription: "把文件拖到这里"),
           let configured = symbol.withSymbolConfiguration(
               NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)) {
            iconView.image = configured
        }
        iconHolder.addSubview(iconView)

        dropView = DropView(frame: rect)
        dropView.autoresizingMask = [.width, .height]
        dropView.onDropped = { [weak self] urls in
            self?.handleLocalDrop(urls)
        }
        dropView.onCrossMachineDrop = { [weak self] names in
            self?.handleCrossMachineDrop(names)
        }
        dropView.onDragEnter = { [weak self] in
            self?.dragEntered()
        }
        dropView.onDragExit = { [weak self] in
            self?.dragExited()
        }

        // 注意顺序：光泽和悬停层落在玻璃之上、交互层之下
        container.addSubview(glass)
        container.addSubview(sheenOverlay)
        container.addSubview(hoverOverlay)
        container.addSubview(dropView)
        dropView.addSubview(iconHolder)
        dropView.addSubview(deviceLabel)
        dropView.addSubview(statusLabel)
        dropView.addSubview(progressBar)

        panel.contentView = container
        currentSize = Self.collapsedSize
        layoutSubviews()

        // 屏幕右上角
        if let scr = NSScreen.main {
            let margin: CGFloat = 20
            panel.setFrameOrigin(NSPoint(x: scr.visibleFrame.maxX - rect.width - margin,
                                          y: scr.visibleFrame.maxY - rect.height - margin))
        }
        playAppearAnimation()
        panel.orderFrontRegardless()
    }

    /// 首次出现：从右上角锚定的小圆「弹」出来
    private func playAppearAnimation() {
        let final = panel.frame
        let inset: CGFloat = 9
        let start = NSRect(x: final.minX + inset * 2,
                           y: final.minY + inset * 2,
                           width: final.width - inset * 2,
                           height: final.height - inset * 2)
        panel.alphaValue = 0
        panel.setFrame(start, display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
    }

    private func layoutSubviews() {
        guard panel != nil else { return }
        let b = dropView.bounds

        if pickerMode {
            // 选择器：顶部问题文案 + 设备行 + 底部取消行
            statusLabel.frame = NSRect(x: 10, y: b.height - 32, width: b.width - 20, height: 20)
            var y = b.height - 64
            for row in pickerRows {
                row.frame = NSRect(x: 14, y: y, width: b.width - 28, height: 28)
                y -= 34
            }
            pickerCancelRow?.frame = NSRect(x: 14, y: 12, width: b.width - 28, height: 28)
            return
        }

        deviceLabel.frame = NSRect(x: 10, y: b.height - 30, width: b.width - 20, height: 18)
        statusLabel.frame = NSRect(x: 10, y: b.height - 64, width: b.width - 20, height: 22)
        progressBar.frame = NSRect(x: 34, y: b.height - 92, width: b.width - 68, height: 8)
        let side: CGFloat = 30
        iconHolder.frame = NSRect(x: (b.width - side) / 2, y: (b.height - side) / 2,
                                  width: side, height: side)
    }

    /// 展开/收起：保持右上角不动，窗口向左下生长、向右上回收。
    private func setExpanded(_ expanded: Bool, animated: Bool) {
        guard panel != nil, expanded != isExpanded else { return }
        isExpanded = expanded

        setExpandedSize(expanded ? Self.expandedSize : Self.collapsedSize,
                        animated: animated)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? Self.morphDuration : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            deviceLabel.animator().alphaValue = expanded ? 1 : 0
            statusLabel.animator().alphaValue = expanded ? 1 : 0
            iconHolder.animator().alphaValue = expanded ? 0 : 1
        }
    }

    /// 改变面板尺寸：保持右上角不动，窗口 frame 与圆角同步形变，避免硬切。
    private func setExpandedSize(_ size: NSSize, animated: Bool) {
        guard panel != nil, size != currentSize else { return }
        currentSize = size

        let target = NSRect(x: panel.frame.maxX - size.width,
                            y: panel.frame.maxY - size.height,
                            width: size.width,
                            height: size.height)
        let isCircle = abs(size.width - size.height) < 1
        let newRadius: CGFloat = isCircle ? size.width / 2 : Self.expandedRadius
        let oldRadius = container.layer?.cornerRadius ?? newRadius
        let duration = animated ? Self.morphDuration : 0

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.layoutSubviews()
            self.panel.invalidateShadow()
        })

        // 圆角是 CALayer 属性，需显式动画才能跟着 frame 一起形变
        container.layer?.cornerRadius = newRadius
        if duration > 0 {
            let radius = CABasicAnimation(keyPath: "cornerRadius")
            radius.fromValue = oldRadius
            radius.toValue = newRadius
            radius.duration = duration
            radius.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            container.layer?.add(radius, forKey: "morph")
        }
    }

    private func dragEntered() {
        isDragHovering = true
        autoShownForTransfer = false  // 用户自己来拖了，之后保持可见
        pendingCollapse?.cancel()
        pendingCollapse = nil
        setHovering(true)
        setExpanded(true, animated: true)
    }

    private func dragExited() {
        isDragHovering = false
        setHovering(false)
        pendingCollapse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapse() }
        pendingCollapse = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// 悬停高亮：整体变亮 + 图标弹性放大（保持中性，不用彩色）
    private func setHovering(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            hoverOverlay.animator().alphaValue = on ? 1 : 0
        }
        animateIconHover(on)
    }

    private func animateIconHover(_ hovering: Bool) {
        guard let layer = iconHolder.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = hovering ? 1.0 : 1.12
        spring.toValue = hovering ? 1.12 : 1.0
        spring.damping = hovering ? 11 : 15
        spring.stiffness = 260
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "iconHover")
        layer.transform = CATransform3DMakeScale(hovering ? 1.12 : 1.0,
                                                 hovering ? 1.12 : 1.0, 1)
        iconView.contentTintColor = hovering ? .white : NSColor.white.withAlphaComponent(0.92)
    }

    private func collapse() {
        guard !isBusy, !isDragHovering else { return }
        setExpanded(false, animated: true)
    }

    func show() {
        if isExpanded && !isBusy && !isDragHovering {
            setExpanded(false, animated: false)
        }
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        if pickerMode {
            tearDownPicker()
            isBusy = false
        }
        panel.orderOut(nil)
    }
    func toggle() { isVisible ? hide() : show() }
    var isVisible: Bool { panel.isVisible }

    // MARK: - 状态

    func updatePeers(_ peers: [Peer]) {
        self.peers = peers
        if pickerMode {
            if peers.isEmpty {
                cancelPicker()
            } else {
                rebuildPicker()
            }
        }
        refreshStatus()
    }

    func setDeviceName(_ name: String) {
        deviceLabel.stringValue = name
    }

    /// 发送中进度（本机把文件发出去）
    func updateProgress(_ fraction: Double) { updateProgress(fraction, verb: "传输中") }

    /// 接收中进度（其他 Mac 发过来的文件）
    func updateReceiveProgress(_ fraction: Double) { updateProgress(fraction, verb: "接收中") }

    private func updateProgress(_ fraction: Double, verb: String) {
        prepareForStatusUI()
        progressBar.isHidden = false
        progressBar.setFraction(fraction, animated: true)
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = String(format: "\(verb) %.0f%%", fraction * 100)
    }

    /// 开始接收：即使面板原来隐藏/收起，也自动出现并展开
    func beginReceive() {
        prepareForStatusUI()
        progressBar.isHidden = false
        progressBar.setFraction(0, animated: false)
        statusLabel.textColor = .labelColor
        statusLabel.stringValue = "正在接收…"
    }

    /// 进度/结果出现前：确保可见、展开、尺寸正确（隐藏则临时唤出，结束后再隐藏）
    private func prepareForStatusUI() {
        isBusy = true
        busyGeneration += 1
        if pickerMode { tearDownPicker() }
        if !isVisible {
            autoShownForTransfer = true
            show()
        }
        if !isExpanded {
            setExpanded(true, animated: true)
        } else if currentSize != Self.expandedSize {
            setExpandedSize(Self.expandedSize, animated: true)
        }
    }

    func finishProgress(text: String, isError: Bool = false) {
        prepareForStatusUI()
        progressBar.isHidden = true
        progressBar.setFraction(0, animated: false)
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        let gen = busyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, gen == self.busyGeneration, !self.pickerMode else { return }
            self.isBusy = false
            self.refreshStatus()
            guard !self.isDragHovering else { return }
            if self.autoShownForTransfer {
                self.autoShownForTransfer = false
                self.hide()
            } else {
                self.collapse()
            }
        }
    }

    func refreshStatus() {
        statusLabel.textColor = .labelColor
        if peers.isEmpty {
            statusLabel.stringValue = "没发现其他 Mac"
            statusLabel.font = .systemFont(ofSize: 13.5)
        } else if peers.count == 1 {
            statusLabel.stringValue = "拖到这里 → \(peers[0].name)"
            statusLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        } else {
            statusLabel.stringValue = "拖到这里（\(peers.count) 台 Mac 可选）"
            statusLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        }
        layoutSubviews()
    }

    // MARK: - 拖放处理

    private func handleLocalDrop(_ urls: [URL]) {
        isBusy = true
        busyGeneration += 1
        guard !peers.isEmpty else {
            finishProgress(text: "没发现其他 Mac", isError: true)
            NSSound.beep()
            return
        }
        if peers.count == 1 {
            statusLabel.stringValue = "准备发送…"
            onSend?(urls, peers[0])
            return
        }
        // 多台在线：先让用户选目标
        showPicker(for: urls)
    }

    // MARK: - 多设备选择器

    /// 多台 Mac 在线时，拖入后弹出的设备列表（AirDrop 式点选目标）
    private func showPicker(for urls: [URL]) {
        pendingURLs = urls
        isBusy = true
        pickerMode = true
        rebuildPicker()
        setExpanded(true, animated: true)
        // 标题占用了设备名的位置，淡出避免叠字
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            deviceLabel.animator().alphaValue = 0
        }
        setExpandedSize(Self.pickerSize(deviceCount: peers.count), animated: true)
        startClickMonitor()
    }

    private func rebuildPicker() {
        for row in pickerRows { row.removeFromSuperview() }
        pickerRows = []
        pickerCancelRow?.removeFromSuperview()

        statusLabel.textColor = .labelColor
        statusLabel.stringValue = "发送到哪台 Mac？"
        statusLabel.font = .systemFont(ofSize: 13.5, weight: .medium)

        for peer in peers.prefix(Self.maxPickerRows) {
            let row = DeviceRow(title: peer.name, symbol: "desktopcomputer")
            row.onClick = { [weak self] in self?.choose(peer) }
            dropView.addSubview(row)
            pickerRows.append(row)
        }
        let cancel = DeviceRow(title: "取消", symbol: nil, secondary: true)
        cancel.onClick = { [weak self] in self?.cancelPicker() }
        dropView.addSubview(cancel)
        pickerCancelRow = cancel

        if pickerMode {
            setExpandedSize(Self.pickerSize(deviceCount: peers.count), animated: true)
        }
        layoutSubviews()
    }

    private static func pickerSize(deviceCount: Int) -> NSSize {
        let n = min(deviceCount, maxPickerRows)
        let height = 64 + CGFloat(n - 1) * 34 + 28 + 20
        return NSSize(width: expandedSize.width, height: height)
    }

    private func choose(_ peer: Peer) {
        let urls = pendingURLs
        tearDownPicker()
        guard !urls.isEmpty else {
            isBusy = false
            refreshStatus()
            return
        }
        statusLabel.stringValue = "准备发送…"
        onSend?(urls, peer)
    }

    private func cancelPicker() {
        tearDownPicker()
        isBusy = false
        refreshStatus()
        if isVisible, !isDragHovering { setExpanded(false, animated: true) }
    }

    /// 清掉选择器 UI 与状态（不动 isBusy，由调用方决定）
    private func tearDownPicker() {
        stopClickMonitor()
        pickerMode = false
        pendingURLs = []
        for row in pickerRows { row.removeFromSuperview() }
        pickerRows = []
        pickerCancelRow?.removeFromSuperview()
        pickerCancelRow = nil
        deviceLabel.alphaValue = isExpanded ? 1 : 0
        layoutSubviews()
    }

    private func startClickMonitor() {
        stopClickMonitor()
        // 点击面板之外的任何地方 = 取消选择
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.pickerMode else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.cancelPicker()
                }
            }
        }
    }

    private func stopClickMonitor() {
        if let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    private func handleCrossMachineDrop(_ names: [String]) {
        isBusy = true
        finishProgress(text: "已接收：\(names.first ?? "")")
    }

    // MARK: - 视觉自查钩子

    /// 测试钩子：强制进入/退出拖拽悬停外观（只影响视觉，不走真实拖拽流程）
    func debugForceHover(_ on: Bool) {
        isDragHovering = on
        setHovering(on)
        if on {
            setExpanded(true, animated: true)
        } else {
            collapse()
        }
    }

    /// 测试钩子：用假的"三台设备在线"数据弹出选择器，检查布局
    func debugShowPicker() {
        let fake = [
            Peer(host: "10.0.1.118", port: 52345, name: "moon_air的MacBook Air"),
            Peer(host: "10.0.1.120", port: 52345, name: "客厅的 Mac mini"),
            Peer(host: "10.0.1.131", port: 52345, name: "MacBook Pro（会议室）")
        ]
        updatePeers(fake)
        showPicker(for: [URL(fileURLWithPath: "/tmp/demo.txt")])
    }

    /// 测试钩子：关闭选择器
    func debugCancelPicker() { cancelPicker() }

    /// 把当前面板的图层树渲染成 PNG（不含毛玻璃底，用灰白棋盘衬底）。
    /// 仅由 AppDelegate 的 MACDROP_UI_PROBE 测试钩子调用，正常运行时不会触发。
    func debugSnapshot(to path: String) {
        guard panel != nil, let root = container.layer else { return }
        let size = container.bounds.size
        let scale: CGFloat = 2
        let pw = Int(size.width * scale)
        let ph = Int(size.height * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }

        // 灰白棋盘底，便于分辨透明区域
        ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
        let cell = 16
        for row in 0..<(ph / cell + 1) {
            for col in stride(from: (row % 2) * cell, to: pw, by: cell * 2) {
                ctx.fill(CGRect(x: col, y: row * cell, width: cell, height: cell))
            }
        }

        ctx.scaleBy(x: scale, y: scale)
        root.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// 实际承载拖放的视图：不画任何描边，只负责接收拖放与鼠标
final class DropView: NSView {

    var onDropped: (([URL]) -> Void)?
    var onCrossMachineDrop: (([String]) -> Void)?
    var onDragEnter: (() -> Void)?
    var onDragExit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDragEnter?()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDragExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        playDropBounce()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        let pasteboard = sender.draggingPasteboard

        // 优先当普通本地文件处理
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onDropped?(urls)
            return true
        }

        // 跨机拖放：只能拿到文件名
        if let names = pasteboard.readObjects(forClasses: [NSString.self],
                                              options: nil) as? [String],
           !names.isEmpty {
            onCrossMachineDrop?(names)
            return true
        }

        return false
    }

    /// 松手落下的瞬间：整个面板轻微回弹一下
    private func playDropBounce() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.93
        spring.toValue = 1.0
        spring.damping = 12
        spring.stiffness = 300
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer?.add(spring, forKey: "dropBounce")
    }

    // MARK: - 鼠标：整块面板都能拖动窗口（选择器行除外）

    /// 除设备列表行外，所有鼠标事件都先落到本视图（图标、文字不拦截），
    /// 按下即进入系统拖拽，保证圆形浮窗任意位置都能拖着走。
    override func hitTest(_ point: NSPoint) -> NSView? {
        var v = super.hitTest(point)
        while let cur = v, cur !== self {
            if cur is DeviceRow { return cur }
            v = cur.superview
        }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 设备列表行：圆角条目 + 悬停高亮 + 手型光标 + 点击回调
final class DeviceRow: NSView {

    var onClick: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let hasIcon: Bool

    init(title: String, symbol: String?, secondary: Bool = false) {
        hasIcon = symbol != nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor

        nameLabel.stringValue = title
        nameLabel.font = .systemFont(ofSize: 12.5, weight: secondary ? .regular : .medium)
        nameLabel.textColor = secondary
            ? NSColor.white.withAlphaComponent(0.72)
            : NSColor.white
        nameLabel.lineBreakMode = .byTruncatingMiddle
        if !hasIcon { nameLabel.alignment = .center }
        addSubview(nameLabel)

        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
            iconView.contentTintColor = NSColor.white.withAlphaComponent(0.6)
            addSubview(iconView)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        if hasIcon {
            iconView.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
            nameLabel.frame = NSRect(x: 36, y: (h - 16) / 2, width: bounds.width - 48, height: 16)
        } else {
            nameLabel.frame = NSRect(x: 12, y: (h - 16) / 2, width: bounds.width - 24, height: 16)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .cursorUpdate,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func setHovered(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        layer?.backgroundColor = NSColor.white.withAlphaComponent(on ? 0.16 : 0.07).cgColor
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 自绘圆角胶囊进度条（比 NSProgressIndicator 更贴合圆形浮窗的风格）
final class RoundedProgressBar: NSView {

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var fraction: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        trackLayer.masksToBounds = true
        fillLayer.masksToBounds = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = bounds.height / 2
        trackLayer.frame = bounds
        trackLayer.cornerRadius = radius
        fillLayer.cornerRadius = radius
        fillLayer.frame = fillFrame()
        CATransaction.commit()
    }

    func setFraction(_ value: Double, animated: Bool) {
        fraction = CGFloat(max(0, min(1, value)))
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            fillLayer.frame = fillFrame()
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.frame = fillFrame()
            CATransaction.commit()
        }
    }

    private func fillFrame() -> CGRect {
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
    }

    private func refreshColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            trackLayer.backgroundColor =
                NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        }
        CATransaction.commit()
    }
}
