import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 相册里选中的图片/视频。
///
/// 用 FileRepresentation 而不是 Data：视频不会整段进内存，照片也不用先解码，
/// 导入时先复制一份到自己的临时目录，之后发送过程不依赖相册的临时授权。
struct PickedMedia: Transferable {

    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            PickedMedia(url: copyToTemp(received.file))
        }

        FileRepresentation(contentType: .image) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            PickedMedia(url: copyToTemp(received.file))
        }
    }

    private static func copyToTemp(_ source: URL) -> URL {
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(moonTF("相册-%@.%@", UUID().uuidString, ext))
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return dest
        } catch {
            return source
        }
    }
}
