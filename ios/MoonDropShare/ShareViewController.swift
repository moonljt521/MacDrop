import UIKit
import UniformTypeIdentifiers

/// 系统分享面板里的 MoonDrop 入口：把文件复制到 App Group，
/// 再唤起主 App，由主 App 选择设备并发送。
final class ShareViewController: UIViewController {

    private static let appGroup = "group.com.macdrop.mobile"
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var started = false
    private var openSettled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在交给 MoonDrop…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)

        openButton.setTitle("打开 MoonDrop 选择设备", for: .normal)
        openButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        openButton.addTarget(self, action: #selector(openAppTapped), for: .touchUpInside)
        openButton.isHidden = true

        doneButton.setTitle("完成", for: .normal)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isHidden = true

        for subview in [spinner, statusLabel, openButton, doneButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 16),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 20),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            doneButton.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 12)
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        handleShare()
    }

    private func handleShare() {
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

                var name = provider.suggestedName ?? "file-\(index + 1)"
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
            self.spinner.stopAnimating()
            self.statusLabel.text = "已加入待发送，尚未发送"
            self.openApp()
        }
    }

    private func openApp() {
        guard let url = URL(string: "moondrop://incoming") else {
            showManualOpen()
            return
        }
        openSettled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.openSettled else { return }
            self.showManualOpen()
        }
        extensionContext?.open(url) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.openSettled = true
                if success {
                    self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
                } else {
                    self.showManualOpen()
                }
            }
        }
    }

    private func showManualOpen() {
        statusLabel.text = "尚未发送。请打开 MoonDrop，选择设备后再发送。"
        openButton.isHidden = false
        doneButton.isHidden = false
    }

    @objc private func openAppTapped() {
        openApp()
    }

    @objc private func doneTapped() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func finish(_ message: String, success: Bool) {
        statusLabel.text = message
        spinner.stopAnimating()
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

    private static func safeName(_ name: String) -> String {
        var value = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { value = "file" }
        return value
    }
}
