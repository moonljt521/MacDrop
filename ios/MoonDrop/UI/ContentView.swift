import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {

    private enum Sheet: Identifiable {
        case manualPeer, settings, help, connection, history
        case sendOptions(Peer)

        var id: String {
            switch self {
            case .manualPeer: return "manual"
            case .settings: return "settings"
            case .help: return "help"
            case .connection: return "connection"
            case .history: return "history"
            case .sendOptions(let peer): return "send:\(peer.endpoint)"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingImporter = false
    @State private var showingPhotos = false
    @State private var sheet: Sheet?
    @State private var nextSheet: Sheet?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var sendTarget: Peer?
    @State private var pickAction: MoonSendAction?

    var body: some View {
        NavigationStack {
            content
                .toolbar { toolbarContent }
                .sheet(item: $sheet, onDismiss: handleSheetDismiss) { item in
                    sheetContent(item)
                }
                .modifier(ContentAttachments(
                    scenePhase: scenePhase,
                    showingImporter: $showingImporter,
                    showingPhotos: $showingPhotos,
                    photoItems: $photoItems,
                    takeSendTarget: takeSendTarget,
                    clearSendTarget: { sendTarget = nil }
                ))
                .modifier(ContentDialogs(
                    showingRename: $showingRename,
                    renameText: $renameText,
                    photoItems: $photoItems,
                    takeSendTarget: takeSendTarget
                ))
        }
        .tint(MoonTheme.primary)
        .onAppear { applyAppearance(prefs.appearance) }
        .onChange(of: prefs.appearance) { appearance in
            applyAppearance(appearance)
        }
    }

    private func applyAppearance(_ appearance: MoonAppearance) {
        let style: UIUserInterfaceStyle = switch appearance {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        // 窗口级覆盖才能让已经弹出的 sheet 同步换色。
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = style }
    }

    private var content: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    identityRow.padding(.bottom, 24)
                    Text(fieldTitle)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(MoonTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(fieldSubtitle)
                        .font(MoonType.body)
                        .foregroundStyle(MoonTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    centralField.padding(.top, 12)
                    discoveryActions
                    if dynamicTypeSize >= .xxxLarge {
                        recentTransfer.padding(.top, 16)
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .frame(maxWidth: 640)
                .frame(minHeight: geometry.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background(MoonTheme.canvas)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomTray }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(MoonTheme.canvas, for: .navigationBar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { brand }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { brand }
        }
        ToolbarItem(placement: .topBarTrailing) {
            MoonCircleButton(symbol: "slider.horizontal.3", label: moonT("设置与更多")) {
                sheet = .settings
            }
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            Image(systemName: "moon.fill").font(.title3).accessibilityHidden(true)
            Text("MoonDrop").font(.title3.weight(.semibold))
        }
        .foregroundStyle(MoonTheme.ink)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func sheetContent(_ item: Sheet) -> some View {
        switch item {
        case .manualPeer:
            ManualPeerSheet().environmentObject(model)
        case .sendOptions(let peer):
            SendOptionsSheet(peer: peer) { action in
                sendTarget = peer
                pickAction = action
                sheet = nil
            }
        case .settings:
            MoonSettingsSheet(
                onOpenConnection: { nextSheet = .connection },
                onOpenHelp: { nextSheet = .help }
            ).environmentObject(model)
        case .help:
            StorageHelpSheet()
        case .connection:
            ConnectionSheet().environmentObject(model)
        case .history:
            MoonHistorySheet().environmentObject(model)
        }
    }

    private var identityRow: some View {
        HStack(spacing: 8) {
            Button { sheet = .connection } label: {
                HStack(spacing: 7) {
                    MoonStatusDot(color: isOnline ? MoonTheme.success : MoonTheme.warning)
                    Text("\(model.deviceName) · \(statusDetail)")
                        .font(MoonType.meta)
                        .foregroundStyle(MoonTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(MoonTheme.textTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(MoonPressStyle())
            .accessibilityLabel(moonTF("连接详情，%@，%@", model.deviceName, statusDetail))
            Spacer(minLength: 0)
            MoonCircleButton(symbol: "pencil", label: moonT("重命名本机")) {
                renameText = model.deviceName
                showingRename = true
            }
        }
    }

    private var isOnline: Bool {
        model.listenPort > 0 && !model.localAddresses.isEmpty && model.isAdvertiseLive
    }

    private var statusDetail: String {
        if model.listenPort <= 0 { return moonT("接收启动中") }
        if model.localAddresses.isEmpty { return moonT("未连接局域网") }
        return model.isAdvertiseLive ? moonT("可接收") : moonT("广播未上线")
    }

    private var fieldState: Int {
        if model.sending { return 1 }
        if model.receiving { return 2 }
        if !model.resultText.isEmpty { return 3 }
        if model.pendingCount > 0 { return 4 }
        return 0
    }

    private var fieldTitle: String {
        switch fieldState {
        case 1: return moonT("文件，正在抵达")
        case 2: return moonT("接收来自附近")
        case 3: return moonT("操作结果")
        case 4: return moonT("准备好，即刻传递")
        default: return moonT("发送到附近")
        }
    }

    private var fieldSubtitle: String {
        switch fieldState {
        case 1, 2: return moonT("设备之间直连，不经过云端")
        case 3: return moonT("每一次传递，都有迹可循")
        case 4: return moonT("共享的文件尚未发送，请选择接收设备")
        default:
            if model.scanning { return scanSubtitle }
            if !model.scanSummary.isEmpty { return model.scanSummary }
            return model.peers.isEmpty
                ? moonT("打开另一台设备上的 MoonDrop")
                : moonTP("%d 台设备在附近，轻点开始传递", model.peers.count)
        }
    }

    /// 扫描中的副标题：说清楚正在做什么、这次扫描找到了几台
    private var scanSubtitle: String {
        model.scanFound > 0
            ? moonTP("正在扫描 · 本次找到 %d 台设备", model.scanFound)
            : moonT("正在扫描 · 正在逐个探测局域网地址")
    }

    private var centralField: some View {
        Group {
            if model.sending {
                MoonTransferCard(mode: .sending(
                    progress: model.sendProgress,
                    detail: model.sendText.isEmpty ? moonT("准备发送…") : model.sendText,
                    large: model.sendLargeFile
                ))
            } else if model.receiving {
                MoonTransferCard(mode: .receiving(
                    progress: model.receiveProgress,
                    detail: model.receiveText.isEmpty ? moonT("接收中…") : model.receiveText
                ))
            } else if !model.resultText.isEmpty {
                MoonTransferCard(mode: .finished(detail: model.resultText, isError: model.resultIsError))
            } else if model.pendingCount > 0 {
                pendingField
            } else {
                MoonPeerField(peers: model.peers,
                              scanning: model.scanning) { peer in
                    UISelectionFeedbackGenerator().selectionChanged()
                    sheet = .sendOptions(peer)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: fieldState)
    }

    private var pendingField: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(MoonTheme.primary)
                .frame(width: 104, height: 104)
                .background(MoonTheme.surface, in: Circle())
                .accessibilityHidden(true)
            Text(moonTP("%d 个文件待发送", model.pendingCount))
                .font(.title3.weight(.semibold))
                .foregroundStyle(MoonTheme.textPrimary)
            MoonPrimaryButton(title: moonT("选择设备并发送"), enabled: !model.peers.isEmpty && !model.sending) {
                model.sendPending()
            }
            MoonTextAction(title: moonT("取消待发送"), enabled: true) { model.cancelPending() }
        }
        .padding(.vertical, 20)
        .frame(minHeight: 330)
    }

    private var discoveryActions: some View {
        let layout = dynamicTypeSize >= .xxxLarge
            ? AnyLayout(VStackLayout(spacing: 0))
            : AnyLayout(HStackLayout(spacing: 20))
        return layout {
            Button { model.scanSubnet() } label: {
                HStack(spacing: 7) {
                    if model.scanning {
                        MoonScanGlyph()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(model.scanning ? moonT("正在扫描") : moonT("重新扫描"))
                }
                .frame(minHeight: 44)
            }
            .disabled(model.scanning)
            .accessibilityLabel(model.scanning
                                ? moonT("正在扫描局域网设备")
                                : moonT("扫描局域网设备"))
            .accessibilityValue(model.scanning
                                ? moonTP("已发现 %d 台设备", model.scanFound)
                                : "")
            Button {
                model.manualError = nil
                sheet = .manualPeer
            } label: {
                Label(moonT("手动连接"), systemImage: "plus").frame(minHeight: 44)
            }
            .accessibilityLabel(moonT("手动添加设备"))
        }
        .font(MoonType.meta)
        .foregroundStyle(MoonTheme.textSecondary)
        .buttonStyle(MoonPressStyle())
        .frame(maxWidth: .infinity)
    }

    private var bottomTray: some View {
        VStack(spacing: 8) {
            MoonSendDock(enabled: !model.peers.isEmpty && !model.sending,
                         onFile: { beginSend(nil, action: .file) },
                         onAlbum: { beginSend(nil, action: .album) })
            if dynamicTypeSize < .xxxLarge {
                recentTransfer
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: 592)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity)
        .background(MoonTheme.canvas)
    }

    private var recentTransfer: some View {
        Button { sheet = .history } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath").font(.body).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(moonT("最近传输"))
                        .font(MoonType.meta.weight(.medium))
                        .foregroundStyle(MoonTheme.textPrimary)
                    Text(recentSummary)
                        .font(MoonType.label)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                MoonChevron()
            }
            .foregroundStyle(MoonTheme.textSecondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(MoonPressStyle())
        .accessibilityLabel(moonTF("传输记录，%@", recentSummary))
    }

    private var recentSummary: String {
        let received = model.received.max { $0.modified < $1.modified }
        let sent = model.sentRecords.max { $0.date < $1.date }
        if let received, sent.map({ received.modified >= $0.date }) ?? true {
            return moonTF("已接收 · %@", received.name)
        }
        if let sent {
            let name = sent.names.count == 1
                ? sent.names[0]
                : moonTF("%d 个文件", sent.names.count)
            return moonTF("已发送 · %@ → %@", name, sent.target)
        }
        return moonT("发送与接收记录，都收在这里")
    }

    private func beginSend(_ peer: Peer?, action: MoonSendAction) {
        sendTarget = peer
        switch action {
        case .file: showingImporter = true
        case .album: showingPhotos = true
        }
    }

    private func takeSendTarget() -> Peer? {
        let target = sendTarget
        sendTarget = nil
        return target
    }

    private func handleSheetDismiss() {
        if let next = nextSheet {
            nextSheet = nil
            sheet = next
            return
        }
        guard let action = pickAction else { return }
        pickAction = nil
        switch action {
        case .file: showingImporter = true
        case .album: showingPhotos = true
        }
    }
}

private struct MoonHistorySheet: View {
    private enum Preview: Identifiable {
        case file(URL), folder(URL)
        var id: String {
            switch self {
            case .file(let url): return "file:\(url.path)"
            case .folder(let url): return "folder:\(url.path)"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var historyTab = 1
    @State private var confirmClearSent = false
    @State private var confirmClearReceived = false
    @State private var preview: Preview?

    var body: some View {
        NavigationStack {
            historyBlock
                .background(MoonTheme.canvas)
                .navigationTitle(moonT("传输记录"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(moonT("关闭")) { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if hasHistory {
                            Button(moonT("清空")) {
                                if historyTab == 1 { confirmClearReceived = true }
                                else { confirmClearSent = true }
                            }
                        }
                    }
                }
                .sheet(item: $preview) { item in
                    switch item {
                    case .file(let url): QuickLookSheet(url: url)
                    case .folder(let url): FolderBrowserView(url: url, store: model.store)
                    }
                }
                .alert(moonT("清空已发送记录？"), isPresented: $confirmClearSent) {
                    Button(moonT("清空记录"), role: .destructive) { model.clearSentRecords() }
                    Button(moonT("取消"), role: .cancel) {}
                } message: {
                    Text(moonT("只清列表，已经发出去的文件不受影响。"))
                }
                .alert(moonT("清空已接收？"), isPresented: $confirmClearReceived) {
                    Button(moonT("删除全部已接收文件"), role: .destructive) { model.clearReceived() }
                    Button(moonT("取消"), role: .cancel) {}
                } message: {
                    Text(moonT("已接收的文件会从「文件 → 我的 iPhone → MoonDrop → Received」里删除，无法恢复。"))
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var hasHistory: Bool {
        historyTab == 1 ? !model.received.isEmpty : !model.sentRecords.isEmpty
    }

    private var historyBlock: some View {
        VStack(spacing: 0) {
            Picker(moonT("记录类型"), selection: $historyTab) {
                Text(moonTF("已发送 %d", model.sentRecords.count)).tag(0)
                Text(moonTF("已接收 %d", model.received.count)).tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityLabel(moonT("记录类型"))
            if !model.resultText.isEmpty {
                Label(model.resultText, systemImage: model.resultIsError ? "exclamationmark.circle" : "info.circle")
                    .font(MoonType.meta)
                    .foregroundStyle(model.resultIsError ? MoonTheme.dangerText : MoonTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
            }
            List {
                if historyTab == 1 { receivedList }
                else { sentList }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var receivedList: some View {
        if model.received.isEmpty {
            MoonEmptyState(symbol: "folder", title: moonT("还没有接收文件"),
                           message: moonT("其他设备发来的文件会按时间出现在这里"))
                .listRowBackground(Color.clear)
        } else {
            ForEach(moonDayGroups(model.received, date: \.modified)) { group in
                Section(group.title) {
                    ForEach(group.items) { item in
                        receivedRow(item).listRowBackground(MoonTheme.surface)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sentList: some View {
        if model.sentRecords.isEmpty {
            MoonEmptyState(symbol: "paperplane", title: moonT("还没有发送记录"),
                           message: moonT("发出的文件会按时间出现在这里"))
                .listRowBackground(Color.clear)
        } else {
            ForEach(moonDayGroups(model.sentRecords, date: \.date)) { group in
                Section(group.title) {
                    ForEach(group.items) { record in
                        sentRow(record).listRowBackground(MoonTheme.surface)
                    }
                }
            }
        }
    }

    private func receivedRow(_ item: ReceivedItem) -> some View {
        HStack(spacing: 8) {
            Button {
                open(item)
            } label: {
                MoonListRow(
                    symbol: fileSymbol(item.name, isDirectory: item.isDirectory),
                    title: item.name,
                    subtitle: "\(Self.sizeText(item.size)) · \(item.modified.formatted(date: .omitted, time: .shortened))"
                ) { EmptyView() }
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    open(item)
                } label: {
                    Label(item.isDirectory ? moonT("打开文件夹") : moonT("打开"), systemImage: "arrow.up.right.square")
                }

                ShareLink(item: item.url) {
                    Label(moonT("分享"), systemImage: "square.and.arrow.up")
                }

                if PhotoSaver.isMedia(item.url), !model.didSaveToPhotos(item) {
                    Button {
                        model.saveToPhotos(item)
                    } label: {
                        Label(moonT("存入相册"), systemImage: "square.and.arrow.down")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    model.delete(item)
                } label: {
                    Label(moonT("删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MoonTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(moonT("更多操作"))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label(moonT("删除"), systemImage: "trash")
            }
        }
    }

    private func sentRow(_ record: SentRecord) -> some View {
        MoonListRow(
            symbol: fileSymbol(record.names.count == 1 ? record.names[0] : "", isDirectory: false),
            title: record.names.count == 1 ? record.names[0] : moonTF("%d 个文件", record.names.count),
            subtitle: "→ \(record.target) · \(Self.sizeText(record.size)) · \(record.date.formatted(date: .omitted, time: .shortened))"
        ) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MoonTheme.success)
                .accessibilityLabel(moonT("已发送"))
        }
    }

    private func open(_ item: ReceivedItem) {
        preview = item.isDirectory ? .folder(item.url) : .file(item.url)
    }

    private func fileSymbol(_ name: String, isDirectory: Bool) -> String {
        if isDirectory { return "folder" }
        switch name.lowercased().split(separator: ".").last.map(String.init) ?? "" {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "svg":
            return "photo"
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "3gp":
            return "film"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg":
            return "music.note"
        case "zip", "rar", "7z", "tar", "gz", "bz2":
            return "doc.zipper"
        case "apk", "xapk", "apks":
            return "app.badge"
        default:
            return "doc.text"
        }
    }

    private func moonDayGroups<Item: Identifiable>(
        _ items: [Item],
        date: KeyPath<Item, Date>
    ) -> [MoonDayGroup<Item>] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [Item]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item[keyPath: date])
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        return order.map { day in
            MoonDayGroup(id: day, title: moonDayTitle(day), items: buckets[day] ?? [])
        }
    }

    private func moonDayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return moonT("今天") }
        if calendar.isDateInYesterday(day) { return moonT("昨天") }
        let language = prefs.language
        let formatter = DateFormatter()
        formatter.locale = language.locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        switch language {
        case .zhHans:
            formatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        case .en:
            formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        }
        return formatter.string(from: day)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 设置弹层：设置项、连接详情、帮助都收在这一层，主屏因此只留四件事。
struct MoonSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var onOpenConnection: () -> Void
    var onOpenHelp: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(moonT("外观"), selection: $prefs.appearance) {
                        ForEach(MoonAppearance.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section {
                    Picker(moonT("语言"), selection: $prefs.language) {
                        ForEach(MoonLanguage.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section {
                    Toggle(moonT("收到的照片自动存入相册"), isOn: $model.autoSaveToPhotos)
                        .tint(MoonTheme.primary)
                }

                Section {
                    Button {
                        onOpenConnection()
                        dismiss()
                    } label: {
                        Label(moonT("连接详情"), systemImage: "link")
                    }

                    Button {
                        onOpenHelp()
                        dismiss()
                    } label: {
                        Label(moonT("存储位置与常见问题"), systemImage: "info")
                    }
                }

                Section {
                    HStack {
                        Text(moonT("版本"))
                        Spacer()
                        Text(version)
                            .foregroundStyle(MoonTheme.textSecondary)
                    }
                }
            }
            // Picker 的当前值会缓存选项文字，换语言时重建列表才能同步刷新。
            .id(prefs.language)
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(MoonTheme.canvas)
            .navigationTitle(moonT("设置"))
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

private struct MoonDayGroup<Item: Identifiable>: Identifiable {
    let id: Date
    let title: String
    let items: [Item]
}

struct ManualPeerSheet: View {

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var prefs = MoonPreferences.shared
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "52345"
    @State private var name = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section(moonT("对端地址")) {
                    TextField(moonT("IP 地址"), text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField(moonT("端口"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(moonT("备注名（可选）"), text: $name)
                }

                if let error = model.manualError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if connecting {
                                ProgressView()
                            } else {
                                Text(moonT("连接"))
                            }
                            Spacer()
                        }
                    }
                    .disabled(connecting || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Text(moonT("对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(moonT("手动添加设备"))
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

    private func connect() {
        connecting = true
        Task {
            let ok = await model.addManualPeer(host: host, portText: port, name: name)
            connecting = false
            if ok { dismiss() }
        }
    }
}


/// 首屏的外部挂载（文件选择、相册、弹层、URL 回调）。
/// 单独拆出来是为了缩短 body 的修饰符链——SwiftUI 的类型检查扛不住长链。
private struct ContentAttachments: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let scenePhase: ScenePhase
    @Binding var showingImporter: Bool
    @Binding var showingPhotos: Bool
    @Binding var photoItems: [PhotosPickerItem]
    let takeSendTarget: () -> Peer?
    let clearSendTarget: () -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let target = takeSendTarget()
                    model.requestSend(urls: urls, to: target)
                case .failure(let error):
                    clearSendTarget()
                    if (error as NSError).code != NSUserCancelledError {
                        model.reportError(error.localizedDescription)
                    }
                }
            }
            .photosPicker(isPresented: $showingPhotos,
                          selection: $photoItems,
                          maxSelectionCount: 20,
                          matching: .any(of: [.images, .videos]))
            .onOpenURL { url in
                if url.scheme == "moondrop" {
                    model.handleSharedLink()
                } else {
                    model.handleIncoming(urls: [url])
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    model.handleForeground()
                }
            }
    }
}

/// 首屏的确认弹窗与结果反馈。
private struct ContentDialogs: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var prefs = MoonPreferences.shared
    @Binding var showingRename: Bool
    @Binding var renameText: String
    @Binding var photoItems: [PhotosPickerItem]
    let takeSendTarget: () -> Peer?

    func body(content: Content) -> some View {
        content
            .alert(moonT("重命名本机"), isPresented: $showingRename) {
                TextField(moonT("例如 书房的那台 iPhone"), text: $renameText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(moonT("保存")) { model.rename(to: renameText) }
                Button(moonT("取消"), role: .cancel) {}
            } message: {
                Text(moonT("其他设备的 MoonDrop 列表里显示这个名字，最长 24 个字符。"))
            }
            .confirmationDialog(moonT("发送到哪台设备？"),
                                isPresented: $model.showingDevicePicker,
                                titleVisibility: .visible) {
                ForEach(model.peers, id: \.endpoint) { peer in
                    Button(moonTF("%@（%@）", peer.name, peer.host)) {
                        model.choosePeer(peer)
                    }
                }
                Button(moonT("取消"), role: .cancel) {
                    model.cancelDevicePicker()
                }
            }
            .onChange(of: photoItems) { items in
                guard !items.isEmpty else { return }
                photoItems = []
                let target = takeSendTarget()
                model.sendFromAlbum(items, to: target)
            }
            .onChange(of: model.resultText) { text in
                guard !text.isEmpty else { return }
                playResultHaptic(for: text)
                let delay: TimeInterval = model.resultIsError ? 8 : 5
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    model.dismissResult(expected: text)
                }
            }
    }

    private func playResultHaptic(for text: String) {
        let isTransfer = moonTextMatches(text, key: "已发送")
            || moonTextMatches(text, key: "发送失败")
            || moonTextMatches(text, key: "已接收")
            || moonTextMatches(text, key: "接收")
            || moonTextMatches(text, key: "存入相册", contains: true)
        guard isTransfer else { return }
        UINotificationFeedbackGenerator().notificationOccurred(model.resultIsError ? .error : .success)
    }
}
