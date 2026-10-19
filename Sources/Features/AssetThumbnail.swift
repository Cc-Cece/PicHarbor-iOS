import SwiftUI
import Photos

/// One read-only image entry point for task, batch and cleanup lists.
struct AssetThumbnail: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    let assetID: String
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    @State private var preview = false
    @State private var type: String?
    @State private var generation = UUID()
    var body: some View {
        Button { preview = true } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(width: 60, height: 60).clipped()
                if let type { Image(systemName: type).font(.caption).padding(4).foregroundStyle(.white).background(.black.opacity(0.5)) }
            }.frame(width: 60, height: 60).background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.borderless).accessibilityLabel(L10n.text("查看照片详情")).accessibilityIdentifier("photo.preview.\(assetID)")
        .task(id: "\(assetID):\(model.library.revision)") {
            cancel(); image = nil; type = nil
            let identifier = generation
            let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard permission == .authorized || permission == .limited,
                  let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            type = asset.mediaType == .video ? "play.fill" : asset.mediaSubtypes.contains(.photoLive) ? "livephoto" : nil
            let options = PHImageRequestOptions(); options.deliveryMode = .opportunistic; options.resizeMode = .fast; options.isNetworkAccessAllowed = false
            request = model.library.images.requestImage(for: asset, targetSize: CGSize(width: 180, height: 180), contentMode: .aspectFill, options: options) { value, info in
                guard info?[PHImageCancelledKey] as? Bool != true else { return }
                DispatchQueue.main.async { if generation == identifier, let value { image = value } }
            }
        }
        .onDisappear { cancel() }
        .sheet(isPresented: $preview) { NavigationStack { AssetPreviewDestination(assetID: assetID) }.environmentObject(model) }
    }
    private func cancel() { generation = UUID(); if let request { model.library.images.cancelImageRequest(request) }; request = nil }
}

struct AssetPreviewDestination: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @Environment(\.dismiss) private var dismiss
    let assetID: String
    private var asset: PHAsset? {
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard permission == .authorized || permission == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
    }
    var body: some View {
        if let asset { AssetDetailView(asset: asset) }
        else {
            ContentUnavailableView(L10n.text("无法查看照片"), systemImage: "photo", description: Text(L10n.text("照片可能已从本机删除，或尚未允许访问。")))
                .navigationTitle(L10n.text("照片详情")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        }
    }
}
