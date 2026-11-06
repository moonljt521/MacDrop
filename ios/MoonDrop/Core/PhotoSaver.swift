import Foundation
import Photos
import UniformTypeIdentifiers

/// 把收到的图片/视频写进系统相册（只申请「添加」权限，不读相册）。
enum PhotoSaver {

    enum MediaKind {
        case image
        case video

        var photoType: PHAssetResourceType { self == .video ? .video : .photo }
    }

    static func kind(for url: URL) -> MediaKind? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        return nil
    }

    static func isMedia(_ url: URL) -> Bool { kind(for: url) != nil }

    /// 结果在主线程回调。
    static func save(_ url: URL, completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        func finish(_ result: Result<Void, Error>) {
            DispatchQueue.main.async { completion?(result) }
        }
        func fail(_ code: Int, _ message: String) {
            finish(.failure(NSError(domain: "MoonDropMobile", code: code, userInfo: [
                NSLocalizedDescriptionKey: message
            ])))
        }

        guard let kind = kind(for: url) else {
            fail(600, moonT("只有图片和视频能存入相册"))
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail(601, moonT("文件已不存在"))
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            // .limited 对「仅添加」同样可用
            guard status == .authorized || status == .limited else {
                fail(603, moonT("没有相册写入权限，请在「设置 → MoonDrop → 照片」里允许"))
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: kind.photoType, fileURL: url, options: nil)
            }, completionHandler: { success, error in
                if success {
                    MobileLog.write("已存入相册：\(url.lastPathComponent)")
                    finish(.success(()))
                } else {
                    MobileLog.write("存入相册失败：\(error?.localizedDescription ?? "未知")")
                    finish(.failure(error ?? NSError(domain: "MoonDropMobile", code: 602,
                                                     userInfo: [NSLocalizedDescriptionKey: moonT("存入相册失败")])))
                }
            })
        }
    }
}
