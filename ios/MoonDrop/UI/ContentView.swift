import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {

    private enum Presentation: Identifiable {
        case manualPeer
        case file(URL)
        case folder(URL)

        var id: String {
            switch self {
            case .manualPeer: return "manual"
            case .file(let url): return "file:\(url.path)"
            case .folder(let url): return "folder:\(url.path)"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingImporter = false
    @State private var presented: Presentation?
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmClearSent = false
    @State private var confirmClearReceived = false

    var body: some View {
        NavigationStack {
            listView
        }
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
            model.sendFromAlbum(items)
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
            sentSection
            receivedSection
            footerSection
        }
        .navigationTitle("MoonDrop")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.requestSend(urls: urls)
            case .failure(let error): model.reportError(error.localizedDescription)
            }
        }
        .sheet(item: $presented) { item in
            switch item {
            case .manualPeer:
                ManualPeerSheet()
                    .environmentObject(model)
            case .file(let url):
                QuickLookSheet(url: url)
            case .folder(let url):
                FolderBrowserView(url: url, store: model.store)
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

    private var localSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.deviceName).font(.headline)
                    Text(model.listenPort > 0 ? "监听端口 \(String(model.listenPort))" : "接收服务启动中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                renameText = model.deviceName
                showingRename = true
            } label: {
                Label("重命名本机", systemImage: "pencil")
            }

            Toggle("收到图片/视频自动存入相册", isOn: $model.autoSaveToPhotos)

            Text(connectSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("本机")
        }
    }

    /// 互相看不见时先看这一行：是没地址、还是广播没上线（本地网络权限被挡）
    private var connectSummary: String {
        let addresses = model.localAddresses
        let addressPart = addresses.isEmpty ? "未取得局域网地址" : addresses.joined(separator: ", ")
        guard model.listenPort > 0 else { return "\(addressPart) · 接收服务启动中" }
        guard model.isAdvertiseLive else {
            return "\(addressPart) · 广播未上线，请在「设置 → 隐私与安全性 → 本地网络」允许 MoonDrop"
        }
        return "\(addressPart) · 广播已上线"
    }

    private var peersSection: some View {
        Section {
            if model.peers.isEmpty {
                Text("未发现设备。确认对端已打开 MoonDrop，并处于同一 Wi-Fi。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("同一 Wi-Fi 的设备会直接出现；附近的 Apple 设备即使连着别的 Wi-Fi，也会以「点对点」出现（Android 设备必须同一 Wi-Fi）。iPhone 切到后台会停止广播，请让对端留在前台；仍看不见就扫描或手动填 IP。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.peers) { peer in
                    HStack {
                        Image(systemName: peer.isManual ? "link" : "desktopcomputer")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(peer.name)
                                if peer.isPeerToPeer {
                                    Text("点对点")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.18))
                                        .cornerRadius(4)
                                }
                            }
                            Text(peer.isPeerToPeer
                                 ? "直连，不在同一 Wi-Fi · \(peer.host):\(String(peer.port))"
                                 : "\(peer.host):\(String(peer.port))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            Button {
                model.scanSubnet()
            } label: {
                Label(model.scanning ? "扫描局域网中…" : "扫描局域网设备", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(model.scanning)

            Button {
                model.manualError = nil
                presented = .manualPeer
            } label: {
                Label("手动添加设备…", systemImage: "plus.circle")
            }
        } header: {
            Text("附近的设备")
        }
    }

    private var sendSection: some View {
        Section {
            Button {
                showingImporter = true
            } label: {
                Label("选择文件发送", systemImage: "doc.badge.plus")
            }
            .disabled(model.peers.isEmpty || model.sending)

            PhotosPicker(selection: $photoItems,
                         maxSelectionCount: 20,
                         matching: .any(of: [.images, .videos])) {
                Label("从相册发送", systemImage: "photo.on.rectangle")
            }
            .disabled(model.peers.isEmpty || model.sending)

            Text(model.peers.isEmpty ? "没有可用设备" : "选完文件后会让你选择目标设备")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("发送")
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        if model.pendingCount > 0 {
            Section {
                Text("待发送 \(model.pendingCount) 个文件，尚未发送")
                    .font(.callout)

                Button {
                    model.sendPending()
                } label: {
                    Label("选择设备并发送", systemImage: "paperplane.fill")
                }
                .disabled(model.peers.isEmpty || model.sending)

                Button(role: .destructive) {
                    model.cancelPending()
                } label: {
                    Text("取消")
                }
            } header: {
                Text("从其他 App 打开")
            }
        }
    }

    @ViewBuilder
    private var transferSection: some View {
        if model.sending || model.receiving || !model.resultText.isEmpty {
            Section {
                if model.sending {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.sendProgress)
                        Text(model.sendText.isEmpty ? "发送中…" : model.sendText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if model.sendLargeFile {
                            Text("大文件传输中，请保持 MoonDrop 在前台；锁屏或切走会中断。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if model.receiving {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: model.receiveProgress)
                        Text(model.receiveText.isEmpty ? "接收中…" : model.receiveText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if !model.resultText.isEmpty {
                    Label(model.resultText,
                          systemImage: model.resultIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.resultIsError ? .red : .green)
                }
            } header: {
                Text("传输")
            }
        }
    }

    private var sentSection: some View {
        Section {
            if model.sentRecords.isEmpty {
                Text("暂无发送记录")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sentRecords) { record in
                    HStack(spacing: 10) {
                        Image(systemName: "paperplane")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.names.count == 1 ? record.names[0] : "\(record.names.count) 个文件")
                                .lineLimit(1)
                            Text("→ \(record.target) · \(Self.sizeText(record.size)) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        } header: {
            HStack {
                Text("已发送")
                Spacer()
                if !model.sentRecords.isEmpty {
                    Button("清空") { confirmClearSent = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var receivedSection: some View {
        Section {
            if model.received.isEmpty {
                Text("暂无接收文件")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.received) { item in
                    HStack(spacing: 10) {
                        Button {
                            presented = item.isDirectory ? .folder(item.url) : .file(item.url)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name)
                                        .lineLimit(1)
                                    Text("\(Self.sizeText(item.size)) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        if PhotoSaver.isMedia(item.url) {
                            Button {
                                model.saveToPhotos(item)
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("存入相册")
                        }

                        ShareLink(item: item.url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete(perform: model.deleteItems)
            }
        } header: {
            HStack {
                Text("已接收")
                Spacer()
                if !model.received.isEmpty {
                    Button("清空") { confirmClearReceived = true }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
                Button("刷新") { model.refreshReceived() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text("接收的文件保存在「文件」App → 我的 iPhone → MoonDrop → Received；图片和视频可同时存入系统相册（见上方开关）。点击文件可直接预览，点击文件夹可进入浏览。接收过程中请保持 MoonDrop 在前台，锁屏或长时间切到后台可能中断传输。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
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
