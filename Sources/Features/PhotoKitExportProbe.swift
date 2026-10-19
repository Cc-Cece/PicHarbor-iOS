import SwiftUI
import Photos

/// UI-test instrumentation only. Release builds return content unchanged.
struct PhotoKitExportProbe: ViewModifier {
    @ObservedObject var model: HarborModel
    #if DEBUG
    @State private var result = ""
    private var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--verify-photo-export") }
    #endif
    @ViewBuilder
    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay(alignment: .top) {
            if enabled && !result.isEmpty {
                Text(result).padding(8).background(.regularMaterial)
                    .accessibilityIdentifier("photokit.export.result")
            }
        }
        .task { await verify() }
        .onChange(of: model.library.revision) { _, _ in Task { await verify() } }
        #else
        content
        #endif
    }
    #if DEBUG
    @MainActor
    private func verify() async {
        guard enabled, result.isEmpty,
              model.library.status == .authorized || model.library.status == .limited,
              let asset = model.library.assets.first(where: { $0.mediaType == .image }) else { return }
        result = L10n.text("正在校验资源导出")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let resources = try await ResourceExporter.export(assetID: asset.localIdentifier, settings: BackupSettings(), directory: directory)
            guard !resources.isEmpty else { throw HarborError("RESOURCE_MISSING") }
            for resource in resources {
                let digest = try ResourceExporter.hash(URL(fileURLWithPath: resource.path))
                guard digest.1 == resource.sha256 && digest.2 == resource.size else { throw HarborError("SOURCE_CHANGED") }
            }
            result = L10n.text("相册资源导出与读取校验通过")
        } catch { result = L10n.text("资源校验失败：{0}", [String(describing: (error as? HarborError)?.code ?? "FILE_ACCESS")]) }
    }
    #endif
}
