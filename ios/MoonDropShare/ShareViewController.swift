import UIKit
import UniformTypeIdentifiers

/// 系统分享面板里的 MoonDrop 入口。
/// 分享扩展不能可靠地唤起宿主 App，所以直接在面板里发现设备并发送；
/// 找不到设备时再把文件留在 App Group，由主 App 取回。
final class ShareViewController: UIViewController {

    private static let appGroup = "group.com.macdrop.mobile"
    private static let deviceIDKey = "com.macdrop.mobile.deviceID"

    /// 分享扩展的运行时间只有几十秒（超时会被系统回收，连 TCP 一起断）。
    /// 按 3 MB/s 左右的 Wi-Fi 速度留足余量，超过 60 MB 就不在扩展里直接传，
    /// 存到待发送由主 App 来发（主 App 会保持屏幕常亮并申请后台时间）。
    private static let directSendLimit: Int64 = 60 * 1024 * 1024

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let devicesStack = UIStackView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let saveButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private let client = TransferClient()
    private var browser: PeerBrowser?
    private var peers: [Peer] = []
    private var files: [OutgoingFile] = []
    private var stagingDir: URL?
    private var discoveryTimeout: DispatchWorkItem?

    private var started = false
    private var sending = false
    private var keptForPending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildUi()
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        prepareFiles()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !sending && !keptForPending {
            removeStaging()
        }
    }

    // MARK: - UI

    private func buildUi() {
        titleLabel.text = "正在准备…"
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        devicesStack.axis = .vertical
        devicesStack.spacing = 4
        devicesStack.alignment = .fill

        progressView.isHidden = true

        saveButton.setTitle("保存到 MoonDrop 待发送", for: .normal)
        saveButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.isHidden = true

        doneButton.setTitle("取消", for: .normal)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            titleLabel, subtitleLabel, spinner, devicesStack,
            progressView, statusLabel, saveButton, doneButton
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28)
        ])
    }

    private func renderDevices() {
        devicesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for peer in peers {
            let button = UIButton(type: .system)
            button.setTitle("\(peer.name)（\(peer.host)）", for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.titleLabel?.numberOfLines = 1
            button.isEnabled = !sending
            button.addAction(UIAction { [weak self] _ in
                self?.send(to: peer)
            }, for: .touchUpInside)
            devicesStack.addArrangedSubview(button)
        }

        guard !peers.isEmpty else { return }
        discoveryTimeout?.cancel()
        spinner.stopAnimating()
        if !sending && !keptForPending {
            titleLabel.text = "发送到哪台设备？"
            subtitleLabel.text = "\(files.count) 个文件"
        }
    }

    private func setBusy(_ busy: Bool) {
        sending = busy
        doneButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        renderDevices()
    }

    // MARK: - 接收分享内容

    private func prepareFiles() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish("没有可发送的文件", success: false)
            return
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            finish("没有可发送的文件", success: false)
            return
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            finish("无法访问共享目录", success: false)
            return
        }

        let pendingRoot = container.appendingPathComponent("Pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: pendingRoot, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        let staging = pendingRoot.appendingPathComponent(".staging-\(sessionID)", isDirectory: true)
        let destination = pendingRoot.appendingPathComponent(sessionID, isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let group = DispatchGroup()
        let lock = NSLock()
        var saved = 0

        for (index, provider) in providers.enumerated() {
            group.enter()
            let type = provider.registeredTypeIdentifiers.first { identifier in
                guard let uti = UTType(identifier) else { return false }
                return uti.conforms(to: .data) || uti.conforms(to: .image) || uti.conforms(to: .movie)
            } ?? UTType.data.identifier

            provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url else { return }

                var name = provider.suggestedName?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if name.isEmpty ||
                    name.range(of: #"^file-\d+$"#, options: .regularExpression) != nil {
                    name = Self.generatedName(index: index)
                }
                let ext = url.pathExtension
                if !ext.isEmpty, !name.lowercased().hasSuffix(".\(ext.lowercased())") {
                    name += ".\(ext)"
                }
                let target = staging.appendingPathComponent(Self.safeName(name))
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    lock.lock()
                    saved += 1
                    lock.unlock()
                } catch {
                    // 单个附件失败不影响其余文件
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            guard saved > 0 else {
                try? FileManager.default.removeItem(at: staging)
                self.finish("文件读取失败", success: false)
                return
            }
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
            } catch {
                self.finish("无法保存文件", success: false)
                return
            }
            self.stagingDir = destination
            self.files = self.outgoingFiles(in: destination)
            guard !self.files.isEmpty else {
                self.finish("没有可发送的文件", success: false)
                return
            }
            // 大文件交给主 App：扩展活不到传输结束，硬传只会传到一半被系统干掉
            let totalSize = self.files.reduce(Int64(0)) { $0 + $1.size }
            if totalSize > Self.directSendLimit {
                let size = ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
                self.saveToPending(notice: "共 \(size)，扩展撑不到传完就会被系统中断，"
                    + "已存为待发送。请打开 MoonDrop 继续发送。")
                return
            }
            self.titleLabel.text = "正在查找设备…"
            self.subtitleLabel.text = "\(self.files.count) 个文件"
            self.beginDiscovery()
        }
    }

    private func outgoingFiles(in directory: URL) -> [OutgoingFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory != true else { return nil }
            return OutgoingFile(
                url: url,
                relativePath: url.lastPathComponent,
                size: Int64(values?.fileSize ?? 0)
            )
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    // MARK: - 设备发现

    private func beginDiscovery() {
        let deviceID = UserDefaults(suiteName: Self.appGroup)?
            .string(forKey: Self.deviceIDKey) ?? ""
        let browser = PeerBrowser(ownID: deviceID)
        browser.onPeersChanged = { [weak self] list in
            guard let self else { return }
            self.peers = list.filter { $0.name != UIDevice.current.name }
            self.renderDevices()
        }
        browser.browse()
        self.browser = browser

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.peers.isEmpty, !self.sending else { return }
            self.spinner.stopAnimating()
            self.titleLabel.text = "未发现其他设备"
            self.subtitleLabel.text = "\(self.files.count) 个文件尚未发送"
            self.statusLabel.text = "确认对方已打开 MoonDrop，并处于同一 Wi-Fi。"
            self.saveButton.isHidden = false
        }
        discoveryTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - 发送

    private func send(to peer: Peer) {
        guard !sending, !files.isEmpty else { return }
        setBusy(true)
        progressView.isHidden = false
        progressView.progress = 0
        statusLabel.text = "准备发送…"

        client.send(files: files, to: peer, progress: { [weak self] sent, total, name in
            DispatchQueue.main.async {
                guard let self else { return }
                let fraction = total > 0 ? Double(sent) / Double(total) : 0
                self.progressView.progress = Float(fraction)
                self.statusLabel.text = "发送中 \(Int(fraction * 100))% · \(name)"
            }
        }, completion: { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sending = false
                switch result {
                case .success:
                    self.keptForPending = true
                    self.progressView.progress = 1
                    self.statusLabel.text = "已发送 \(self.files.count) 个文件到 \(peer.name)"
                    self.removeStaging()
                    self.browser?.stop()
                    self.browser = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                    }
                case .failure(let error):
                    self.progressView.isHidden = true
                    self.statusLabel.text = "发送失败：\(error.localizedDescription)"
                    self.titleLabel.text = "发送失败"
                    self.saveButton.isHidden = false
                    self.setBusy(false)
                }
            }
        })
    }

    // MARK: - 兜底

    private func saveToPending(notice: String? = nil) {
        guard let staging = stagingDir else {
            finish("没有可保存的文件", success: false)
            return
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
        ) else {
            finish("无法访问共享目录", success: false)
            return
        }
        let pendingRoot = container.appendingPathComponent("Pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
        let destination = pendingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            statusLabel.text = "保存失败：\(error.localizedDescription)"
            return
        }
        stagingDir = nil
        keptForPending = true
        browser?.stop()
        browser = nil
        saveButton.isHidden = true
        progressView.isHidden = true
        titleLabel.text = "已保存到 MoonDrop"
        subtitleLabel.text = "\(files.count) 个文件尚未发送"
        statusLabel.text = notice ?? "打开 MoonDrop 会直接弹出设备选择。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    @objc private func saveTapped() {
        saveToPending()
    }

    @objc private func doneTapped() {
        guard !sending else { return }
        removeStaging()
        browser?.stop()
        browser = nil
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func removeStaging() {
        guard let staging = stagingDir else { return }
        try? FileManager.default.removeItem(at: staging)
        stagingDir = nil
    }

    private func finish(_ message: String, success: Bool) {
        titleLabel.text = message
        subtitleLabel.text = ""
        statusLabel.text = ""
        spinner.stopAnimating()
        browser?.stop()
        browser = nil
        if !success { removeStaging() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let context = self?.extensionContext else { return }
            if success {
                context.completeRequest(returningItems: [], completionHandler: nil)
            } else {
                context.cancelRequest(withError: NSError(
                    domain: "MoonDropShare",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        }
    }

    // MARK: - 命名

    /// 相册分享常常拿不到原始文件名（统一叫 file-1），用时间戳区分。
    private static func generatedName(index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        return index == 0 ? "分享文件-\(stamp)" : "分享文件-\(stamp)-\(index + 1)"
    }

    private static func safeName(_ name: String) -> String {
        var value = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = "file" }
        return value
    }
}
