import SwiftUI
import QuickLook

struct PreviewItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// 用系统 QuickLook 预览，常见文件类型无需额外阅读器。
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// 预览容器：QuickLook 自身没有关闭按钮，这里补一个右上角的显式关闭。
struct QuickLookSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QuickLookPreview(url: url)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .padding(.top, 12)
            .padding(.trailing, 14)
            .accessibilityLabel("关闭预览")
        }
    }
}

struct FolderBrowserView: View {
    let url: URL
    let store: FileStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolderContentsView(url: url, store: store)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}

private struct FolderContentsView: View {
    let url: URL
    let store: FileStore

    @State private var items: [ReceivedItem] = []
    @State private var previewItem: PreviewItem?

    var body: some View {
        List(items) { item in
            if item.isDirectory {
                NavigationLink {
                    FolderContentsView(url: item.url, store: store)
                } label: {
                    ReceivedFileRow(item: item)
                }
            } else {
                Button {
                    previewItem = PreviewItem(url: item.url)
                } label: {
                    ReceivedFileRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .task { items = store.items(in: url) }
        .sheet(item: $previewItem) { item in
            QuickLookSheet(url: item.url)
        }
    }
}

struct ReceivedFileRow: View {
    let item: ReceivedItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                Text("\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)) · \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
