import Foundation

/// 接收端文件存放：Documents/Received 对「文件」App 可见，暂存放 Application Support。
final class FileStore {

    let root: URL
    let receivedDir: URL
    let stagingDir: URL

    private let fm = FileManager.default

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs

        receivedDir = docs.appendingPathComponent("Received", isDirectory: true)
        stagingDir = ConfigSupport.supportDir.appendingPathComponent("Staging", isDirectory: true)

        try? fm.createDirectory(at: receivedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        cleanupStaging()
    }

    func allocateStaging(transferID: String, fileName: String) throws -> URL {
        let url = stagingDir.appendingPathComponent("\(transferID)__\(sanitize(fileName))")
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// 校验字节数后移动到接收目录。校验失败会删除暂存文件并抛错。
    func finalize(staging: URL, fileName: String, relativePath: String?,
                  rootName: String?, expectedSize: Int64) throws -> URL {
        let attrs = try? fm.attributesOfItem(atPath: staging.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else {
            try? fm.removeItem(at: staging)
            throw NSError(domain: "MoonDropMobile", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "文件不完整：已收 \(size) / \(expectedSize) 字节"
            ])
        }

        var targetDir = receivedDir
        for component in relativeDirectories(path: relativePath, root: rootName) {
            targetDir.appendPathComponent(component, isDirectory: true)
        }
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let dest = uniqueURL(in: targetDir, name: sanitize(fileName))
        try fm.moveItem(at: staging, to: dest)
        return dest
    }

    func discardStaging(_ url: URL) {
        try? fm.removeItem(at: url)
    }

    func receivedItems() -> [ReceivedItem] {
        items(in: receivedDir)
    }

    func items(in directory: URL) -> [ReceivedItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles]) else {
            return []
        }
        return urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            var size = Int64(values?.fileSize ?? 0)
            if isDir {
                size = directorySize(url)
            }
            return ReceivedItem(url: url,
                                name: url.lastPathComponent,
                                isDirectory: isDir,
                                size: size,
                                modified: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// 把拖入的 URL 展开成待发送文件；目录递归，relativePath 保留顶层目录名。
    func expandForSending(urls: [URL]) -> [OutgoingFile] {
        var out: [OutgoingFile] = []

        func walk(_ url: URL, prefix: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
            if isDir.boolValue {
                guard let kids = try? fm.contentsOfDirectory(at: url,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
                for kid in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    walk(kid, prefix: "\(prefix)/\(kid.lastPathComponent)")
                }
            } else {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                out.append(OutgoingFile(url: url, relativePath: prefix, size: size))
            }
        }

        for url in urls {
            walk(url, prefix: url.lastPathComponent)
        }
        return out
    }

    func sanitize(_ name: String) -> String {
        var value = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "." || value == ".." {
            value = "_"
        }
        return value
    }

    /// path 的目录部分还原为多级目录；path 只有文件名时用 root 兜底。
    private func relativeDirectories(path: String?, root: String?) -> [String] {
        let directories = ((path ?? "") as NSString).deletingLastPathComponent
        var components = directories.split(separator: "/")
            .map { sanitize(String($0)) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        if components.isEmpty, let root, !root.isEmpty {
            components = [sanitize(root)]
        }
        return components
    }

    func uniqueURL(in dir: URL, name: String) -> URL {
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let next = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
            if index > 999 {
                return dir.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
            }
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory != true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    private func cleanupStaging() {
        guard let items = try? fm.contentsOfDirectory(at: stagingDir,
                                                     includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}

enum ConfigSupport {
    static var supportDir: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MoonDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
