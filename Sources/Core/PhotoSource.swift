import Foundation
import Photos
import PhotosUI
import SwiftUI

enum PhotoSource {
    struct Original { let url: URL; let name: String }

    static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func exportOriginal(assetID: String, staging: URL) async throws -> Original {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw HarborError("PHOTO_PERMISSION")
        }
        guard asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive),
              let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }) else {
            throw HarborError("UNSUPPORTED_MEDIA")
        }
        let name = (resource.originalFilename as NSString).lastPathComponent
        let url = staging.appendingPathComponent(UUID().uuidString).appendingPathExtension((name as NSString).pathExtension)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if error != nil { continuation.resume(throwing: HarborError("FILE_ACCESS")) }
                    else { continuation.resume() }
                }
            }
            return Original(url: url, name: name)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

struct OriginalPhotoPicker: UIViewControllerRepresentable {
    var selected: (String) -> Void
    var failed: () -> Void
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = 1
        configuration.filter = .images
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: OriginalPhotoPicker
        init(_ parent: OriginalPhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let result = results.first else { return }
            guard let id = result.assetIdentifier else { parent.failed(); return }
            parent.selected(id)
        }
    }
}
