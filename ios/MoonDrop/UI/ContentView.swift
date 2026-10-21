import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

    private enum ImportKind { case files, folder }

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

    @State private var importKind: ImportKind = .files
    @State private var showingImporter = false
    @State private var presented: Presentation?

    var body: some View {
        NavigationStack {
            List {
                localSection
                peersSection
                pendingSection
                sendSection
                transferSection
                receivedSection
                footerSection
            }
            .navigationTitle("MoonDrop")
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: importKind == .files ? [.data] : [.folder],
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
            .onOpenURL { url in
                if url.scheme == "moondrop" {
                    model.ingestSharedFiles()
                } else {
                    model.handleIncoming(urls: [url])
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    model.ingestSharedFiles()
                }
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
        } header: {
            Text("本机")
        }
    }

    private var peersSection: some View {
        Section {
            if model.peers.isEmpty {
                Text("未发现设备。确认对端已打开 MoonDrop，并处于同一 Wi-Fi。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.peers) { peer in
                    HStack {
                        Image(systemName: peer.isManual ? "link" : "desktopcomputer")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                            Text("\(peer.host):\(String(peer.port))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

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
                importKind = .files
                showingImporter = true
            } label: {
                Label("选择文件发送", systemImage: "doc.badge.plus")
            }
            .disabled(model.peers.isEmpty || model.sending)

            Button {
                importKind = .folder
                showingImporter = true
            } label: {
                Label("选择文件夹发送", systemImage: "folder.badge.plus")
            }
            .disabled(model.peers.isEmpty || model.sending)

            Text(model.peers.isEmpty ? "没有可用设备" : "选择文件后会让你选择目标设备")
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
                Button("刷新") { model.refreshReceived() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
        }
    }

    private var footerSection: some View {
        Section {
            Text("接收的文件保存在「文件」App → 我的 iPhone → MoonDrop → Received。点击文件可直接预览，点击文件夹可进入浏览。接收过程中请保持 MoonDrop 在前台，锁屏或长时间切到后台可能中断传输。")
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
