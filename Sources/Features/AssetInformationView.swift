import SwiftUI
import Photos
import MapKit
import UniformTypeIdentifiers

struct AssetInformationView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @Environment(\.dismiss) private var dismiss
    let asset: PHAsset
    let resources: [PHAssetResource]
    let sizes: [Int: Int64]
    @State private var camera: [String: String] = [:]
    var body: some View {
        List {
            Section {
                ForEach(resources.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resources[index].originalFilename).textSelection(.enabled)
                        Text(UTType(resources[index].uniformTypeIdentifier)?.preferredFilenameExtension?.uppercased() ?? resources[index].uniformTypeIdentifier).font(.caption).foregroundStyle(.secondary)
                        if let size = sizes[index] { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption) }
                    }
                }
                if let date = asset.creationDate { LabeledContent(L10n.text("拍摄时间"), value: L10n.date(date, date: .long, time: .short)) }
                LabeledContent(L10n.text("分辨率"), value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
                if asset.duration > 0 { LabeledContent(L10n.text("时长"), value: String(format: "%.1f s", asset.duration)) }
            }
            if !camera.isEmpty { Section(L10n.text("拍摄信息")) {
                metadata("camera", L10n.text("设备"))
                metadata("lens", L10n.text("镜头"))
                metadata("iso", "ISO")
                metadata("aperture", L10n.text("光圈"), prefix: "ƒ/")
                metadata("exposure", L10n.text("曝光时间"), suffix: " s")
                metadata("focal", L10n.text("焦距"), suffix: " mm")
                metadata("bias", L10n.text("曝光补偿"), suffix: " EV")
            } }
            if let location = asset.location { Section(L10n.text("拍摄位置")) {
                Map(initialPosition: .region(MKCoordinateRegion(center: location.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)))) { Marker(L10n.text("拍摄位置"), coordinate: location.coordinate) }.frame(height: 180)
                Text(String(format: "%.6f, %.6f", location.coordinate.latitude, location.coordinate.longitude)).textSelection(.enabled)
            } }
        }.navigationTitle(L10n.text("详情")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
        .task { camera = await AssetInformation.camera(asset) }
    }
    @ViewBuilder private func metadata(_ key: String, _ label: String, prefix: String = "", suffix: String = "") -> some View {
        if let value = camera[key] { LabeledContent(label, value: prefix + value + suffix) }
    }
}

struct AssetShareSheet: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
