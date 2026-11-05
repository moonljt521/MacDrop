import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {

    private enum Sheet: Identifiable {
        case manualPeer
        case file(URL)
        case folder(URL)
        case sendOptions(Peer)
        case help
        case connection

        var id: String {
            switch self {
            case .manualPeer: return "manual"
            case .file(let url): return "file:\(url.path)"
            case .folder(let url): return "folder:\(url.path)"
            case .sendOptions(let peer): return "send:\(peer.endpoint)"
            case .help: return "help"
            case .connection: return "connection"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingImporter = false
    @State private var showingPhotos = false
    @State private var sheet: Sheet?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmClearSent = false
    @State private var confirmClearReceived = false

    /// 0 = 已发送，1 = 已接收；默认看收到的
    @State private var historyTab = 1
    /// 设备行选完「文件 / 相册」后真正要去的设备
    @State private var sendTarget: Peer?
    @State private var pickAction: MoonSendAction?

    var body: some View {
        NavigationStack {
            listView
        }
        .tint(MoonTheme.primary)
        .alert("重命名本机", isPresented: $showingRename) {
            TextField("例如 书房的那台 iPhone", text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") { model.rename(to: renameText) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("其他设备的 MoonDrop 列表里显示这个名字，最长 24 个字符。")
        }
        .confirmationDialog("清空已发送记录？", isPresented: $confirmClearSent) {
            Button("清空记录", role: .destructive) { model.clearSentRecords() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清列表，已经发出去的文件不受影响。")
        }
        .confirmationDialog("清空已接收？", isPresented: $confirmClearReceived) {
            Button("删除全部已接收文件", role: .destructive) { model.clearReceived() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已接收的文件会从「文件 → 我的 iPhone → MoonDrop → Received」里删除，无法恢复。")
        }
        .confirmationDialog("发送到哪台设备？",
                            isPresented: $model.showingDevicePicker,
                            titleVisibility: .visible) {
            ForEach(model.peers) { peer in
                Button("\(peer.name)（\(peer.host)）") {
                    model.choosePeer(peer)
                }
            }
            Button("取消", role: .cancel) {
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

    /// 单独拆出来，避免 body 的修饰符链太长导致编译器超时
    private var listView: some View {
        List {
            localSection
            peersSection
            pendingSection
            sendSection
            transferSection
            historyFilterSection
            historySections
            helpSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(MoonTheme.canvas)
        .navigationTitle("MoonDrop")
        .navigationBarTitleDisplayMode(.large)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                let target = takeSendTarget()
                model.requestSend(urls: urls, to: target)
            case .failure(let error):
                sendTarget = nil
                if (error as NSError).code != NSUserCancelledError {
                    model.reportError(error.localizedDescription)
                }
            }
        }
        .photosPicker(isPresented: $showingPhotos,
                      selection: $photoItems,
                      maxSelectionCount: 20,
                      matching: .any(of: [.images, .videos]))
        .sheet(item: $sheet, onDismiss: handleSheetDismiss) { item in
            switch item {
            case .manualPeer:
                ManualPeerSheet()
                    .environmentObject(model)
            case .file(let url):
                QuickLookSheet(url: url)
            case .folder(let url):
                FolderBrowserView(url: url, store: model.store)
            case .sendOptions(let peer):
                SendOptionsSheet(peer: peer) { action in
                    sendTarget = peer
                    pickAction = action
                    sheet = nil
                }
            case .help:
                StorageHelpSheet()
            case .connection:
                ConnectionSheet()
                    .environmentObject(model)
            }
        }
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

    // MARK: - 本机

    private var localSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                MoonIconTile(symbol: "iphone.gen3", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(model.deviceName)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(MoonTheme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        MoonStatusPill(
                            text: statusLabel,
                            textColor: isOnline ? MoonTheme.successText : MoonTheme.textSecondary,
                            dotColor: statusDot,
                            background: isOnline ? MoonTheme.successTint : MoonTheme.surfaceMuted
                        )
                        .fixedSize()
                    }
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(MoonTheme.textSecondary)
                        .lineLimit(1)
                }

                Button {
                    renameText = model.deviceName
                    showingRename = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MoonTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("重命名本机")
            }
            .padding(.vertical, 2)

            Toggle("收到的照片自动存入相册", isOn: $model.autoSaveToPhotos)
                .tint(MoonTheme.primary)

            Button {
                sheet = .connection
            } label: {
                HStack(spacing: 8) {
                    Text("连接详情")
                        .foregroundStyle(MoonTheme.textPrimary)
                    Spacer(minLength: 8)
                    Text(connectionShort)
                        .font(.footnote)
                        .foregroundStyle(MoonTheme.textSecondary)
                        .lineLimit(1)
                    MoonChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("本机")
        }
        .listRowBackground(MoonTheme.surface)
    }

    private var isOnline: Bool {
        model.listenPort > 0 && !model.localAddresses.isEmpty && model.isAdvertiseLive
    }

    private var statusLabel: String {
        if model.listenPort <= 0 { return "启动中" }
        if model.localAddresses.isEmpty { return "未连接局域网" }
        return model.isAdvertiseLive ? "在线" : "广播未上线"
    }

    private var statusDot: Color {
        if model.listenPort <= 0 { return MoonTheme.textTertiary }
        return isOnline ? MoonTheme.success : MoonTheme.warning
    }

    private var metaLine: String {
        guard model.listenPort > 0 else { return "接收服务启动中…" }
        let address = model.localAddresses.first ?? "未连接局域网"
        return "端口 \(String(model.listenPort)) · \(address)"
    }

    private var connectionShort: String {
        if model.listenPort > 0, let address = model.localAddresses.first {
            return address
        }
        return statusLabel
    }

    // MARK: - 附近设备

    private var peersSection: some View {
        Section {
            if model.peers.isEmpty {
                MoonEmptyState(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "还没有发现设备",
                    message: "打开对端 MoonDrop，并连到同一个 Wi-Fi。仍看不见就扫描或手动添加。"
                )
            } else {
                ForEach(model.peers) { peer in
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        sheet = .sendOptions(peer)
                    } label: {
                        MoonDeviceRow(peer: peer)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("点按选择文件或从相册发送")
                }
            }

            Button {
                model.scanSubnet()
            } label: {
                Label(model.scanning ? "扫描局域网中…" : "扫描局域网",
                      systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(model.scanning)

            Button {
                model.manualError = nil
                sheet = .manualPeer
            } label: {
                Label("手动添加设备…", systemImage: "plus.circle")
            }
        } header: {
            HStack {
                Text("附近设备")
                Spacer()
                if !model.peers.isEmpty {
                    Text("\(model.peers.count) 台")
                        .font(.footnote)
                        .foregroundStyle(MoonTheme.textSecondary)
                }
            }
        }
        .listRowBackground(MoonTheme.surface)
    }

    // MARK: - 待发送

    @ViewBuilder
    private var pendingSection: some View {
        if model.pendingCount > 0 {
            Section {
                Label("\(model.pendingCount) 个文件待发送", systemImage: "tray.and.arrow.down")
                    .font(.callout)
                    .foregroundStyle(MoonTheme.textPrimary)

                Button {
                    model.sendPending()
                } label: {
                    Label("选择设备并发送", systemImage: "paperplane.fill")
                }
                .disabled(model.peers.isEmpty || model.sending)

                Button("取消", role: .destructive) {
                    model.cancelPending()
                }
            } header: {
                Text("从其他 App 打开")
            }
            .listRowBackground(MoonTheme.surface)
        }
    }

    // MARK: - 发送

    private var sendSection: some View {
        Section {
            VStack(spacing: 10) {
                Button {
                    beginSend(nil, action: .file)
                } label: {
                    Label("选择文件发送", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MoonTheme.onPrimary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    beginSend(nil, action: .album)
                } label: {
                    Label("从相册发送", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.vertical, 2)
            .disabled(model.peers.isEmpty || model.sending)

            Text(sendHint)
                .font(.caption)
                .foregroundStyle(MoonTheme.textSecondary)
        } header: {
            Text("发送")
        }
        .listRowBackground(MoonTheme.surface)
    }

    private var sendHint: String {
        if model.sending { return "正在传输，请稍候" }
        if model.peers.isEmpty { return "先连接一台设备才能发送" }
        return "选完文件后会让你确认目标设备，也可以直接点上面的设备发送"
    }

    // MARK: - 传输

    @ViewBuilder
    private var transferSection: some View {
        if model.sending {
            Section {
                MoonTransferCard(mode: .sending(
                    progress: model.sendProgress,
                    detail: model.sendText.isEmpty ? "准备发送…" : model.sendText,
                    large: model.sendLargeFile
                ))
            } header: {
                Text("传输")
            }
            .listRowBackground(MoonTheme.surface)
        } else if model.receiving {
            Section {
                MoonTransferCard(mode: .receiving(
                    progress: model.receiveProgress,
                    detail: model.receiveText.isEmpty ? "接收中…" : model.receiveText
                ))
            } header: {
                Text("传输")
            }
            .listRowBackground(MoonTheme.surface)
        } else if !model.resultText.isEmpty {
            Section {
                MoonTransferCard(mode: .finished(
                    detail: model.resultText,
                    isError: model.resultIsError
                ))
            } header: {
                Text("传输")
            }
            .listRowBackground(MoonTheme.surface)
        }
    }

    // MARK: - 记录

    private var hasHistory: Bool {
        historyTab == 1 ? !model.received.isEmpty : !model.sentRecords.isEmpty
    }

    private var historyFilterSection: some View {
        Section {
            Picker("记录类型", selection: $historyTab) {
                Text("已发送 \(model.sentRecords.count)").tag(0)
                Text("已接收 \(model.received.count)").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 2, trailing: 0))
            .listRowBackground(Color.clear)
            .accessibilityLabel("记录类型")
        } header: {
            HStack {
                Text("记录")
                Spacer()
                if hasHistory {
                    Button("清空") {
                        if historyTab == 1 {
                            confirmClearReceived = true
                        } else {
                            confirmClearSent = true
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    @ViewBuilder
    private var historySections: some View {
        if historyTab == 1 {
            if model.received.isEmpty {
                Section {
                    MoonEmptyState(
                        symbol: "folder",
                        title: "还没有接收文件",
                        message: "其他设备发来的文件会按时间出现在这里"
                    )
                }
                .listRowBackground(MoonTheme.surface)
            } else {
                ForEach(moonDayGroups(model.received, date: \.modified)) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            receivedRow(item)
                        }
                    }
                    .listRowBackground(MoonTheme.surface)
                }
            }
        } else {
            if model.sentRecords.isEmpty {
                Section {
                    MoonEmptyState(
                        symbol: "paperplane",
                        title: "还没有发送记录",
                        message: "发出的文件会按时间出现在这里"
                    )
                }
                .listRowBackground(MoonTheme.surface)
            } else {
                ForEach(moonDayGroups(model.sentRecords, date: \.date)) { group in
                    Section(group.title) {
                        ForEach(group.items) { record in
                            sentRow(record)
                        }
                    }
                    .listRowBackground(MoonTheme.surface)
                }
            }
        }
    }

    private func receivedRow(_ item: ReceivedItem) -> some View {
        HStack(spacing: 8) {
            Button {
                open(item)
            } label: {
                HStack(spacing: 12) {
                    MoonIconTile(symbol: fileSymbol(item.name, isDirectory: item.isDirectory))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(MoonTheme.textPrimary)
                            .lineLimit(1)
                        Text("\(Self.sizeText(item.size)) · \(item.modified.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(MoonTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    open(item)
                } label: {
                    Label(item.isDirectory ? "打开文件夹" : "打开", systemImage: "arrow.up.right.square")
                }

                ShareLink(item: item.url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }

                if PhotoSaver.isMedia(item.url), !model.didSaveToPhotos(item) {
                    Button {
                        model.saveToPhotos(item)
                    } label: {
                        Label("存入相册", systemImage: "square.and.arrow.down")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    model.delete(item)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(MoonTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.delete(item)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func sentRow(_ record: SentRecord) -> some View {
        HStack(spacing: 12) {
            MoonIconTile(symbol: fileSymbol(record.names.count == 1 ? record.names[0] : "", isDirectory: false))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.names.count == 1 ? record.names[0] : "\(record.names.count) 个文件")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MoonTheme.textPrimary)
                    .lineLimit(1)
                Text("→ \(record.target) · \(Self.sizeText(record.size)) · \(record.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(MoonTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MoonTheme.success)
                .accessibilityLabel("已发送")
        }
    }

    // MARK: - 帮助与页脚

    private var helpSection: some View {
        Section {
            Button {
                sheet = .help
            } label: {
                HStack(spacing: 12) {
                    MoonIconTile(symbol: "info", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("存储位置与常见问题")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(MoonTheme.textPrimary)
                        Text("文件保存在哪、看不见设备怎么办")
                            .font(.caption)
                            .foregroundStyle(MoonTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    MoonChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(MoonTheme.surface)
    }

    private var footerSection: some View {
        Section {
            Text("MoonDrop · 局域网直连，不经过云端")
                .font(.caption)
                .foregroundStyle(MoonTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - Actions

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
        guard let action = pickAction else { return }
        pickAction = nil
        switch action {
        case .file: showingImporter = true
        case .album: showingPhotos = true
        }
    }

    private func open(_ item: ReceivedItem) {
        sheet = item.isDirectory ? .folder(item.url) : .file(item.url)
    }

    private func playResultHaptic(for text: String) {
        let isTransfer = text.hasPrefix("已发送")
            || text.hasPrefix("发送失败")
            || text.hasPrefix("已接收")
            || text.hasPrefix("接收")
            || text.contains("存入相册")
        guard isTransfer else { return }
        UINotificationFeedbackGenerator().notificationOccurred(model.resultIsError ? .error : .success)
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
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = .current
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        formatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: day)
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MoonDayGroup<Item: Identifiable>: Identifiable {
    let id: Date
    let title: String
    let items: [Item]
}

struct ManualPeerSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "52345"
    @State private var name = ""
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("对端地址") {
                    TextField("IP 地址", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("备注名（可选）", text: $name)
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
                                Text("连接")
                            }
                            Spacer()
                        }
                    }
                    .disabled(connecting || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    Text("对端需运行 MoonDrop（Mac / iPhone / Android），并与本机在同一局域网。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手动添加设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
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
