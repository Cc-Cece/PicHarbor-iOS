import SwiftUI
import AVFoundation
import PhotosUI

struct SubscriptionScannerView: View {
    let onSubscription: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed = false
    @State private var checkedPermission = false
    @State private var cameraID = UUID()
    @State private var scanning = true
    @State private var message = ""
    @State private var selectedImage: PhotosPickerItem?
    @State private var readingImage = false
    @State private var choices: [String] = []
    @State private var active = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if cameraAllowed && scanning && scenePhase == .active && !readingImage {
                        QRCodeCamera(onCode: received, onFailure: { message = L10n.text("相机暂不可用，可从相册选择二维码。"); scanning = false })
                            .id(cameraID).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 20))
                            .accessibilityLabel(L10n.text("将订阅二维码放入取景框"))
                    } else {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 80)).foregroundStyle(.secondary).frame(height: 200)
                    }
                    Text(L10n.text("扫描 HTTP 或 HTTPS 订阅链接，确认后再添加。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.callout) }
                    if readingImage { ProgressView(L10n.text("正在识别二维码…")) }
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, url in
                        Button(L10n.text("订阅 {0} · {1}", [String(index + 1), URL(string: url)?.host ?? ""])) { complete(url) }
                    }
                    PhotosPicker(selection: $selectedImage, matching: .images, photoLibrary: .shared()) {
                        Label(L10n.text("从相册选择二维码"), systemImage: "photo")
                    }.disabled(readingImage)
                    if cameraAllowed && !scanning {
                        Button(L10n.text("继续扫描")) { choices = []; message = ""; cameraID = UUID(); scanning = true }
                    } else if checkedPermission && !cameraAllowed {
                        Button(L10n.text("前往系统设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }.padding()
            }
            .navigationTitle(L10n.text("扫码添加订阅"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        }
        .task {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: cameraAllowed = true
            case .notDetermined: cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            default: cameraAllowed = false
            }
            checkedPermission = true
            if !cameraAllowed { message = L10n.text("未获得相机权限，仍可从相册选择二维码。") }
        }
        .onAppear { active = true }
        .onDisappear { active = false }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && checkedPermission {
                cameraAllowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                if cameraAllowed && scanning { message = "" }
            }
        }
        .onChange(of: selectedImage) { _, item in
            guard let item else { return }
            readingImage = true; scanning = false; message = ""; choices = []
            Task { @MainActor in
                defer { readingImage = false; selectedImage = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw HarborError("QR_IMAGE_UNAVAILABLE") }
                    let payloads = try await Task.detached(priority: .userInitiated) { try SubscriptionQRCode.messages(in: data) }.value
                    guard !payloads.isEmpty else { throw HarborError("QR_NOT_FOUND") }
                    var seen = Set<String>()
                    let urls = payloads.compactMap { try? SubscriptionQRCode.subscription($0) }.filter { seen.insert($0).inserted }
                    if urls.count == 1 { complete(urls[0]) }
                    else if urls.count > 1 { choices = urls; message = L10n.text("请选择要添加的订阅。") }
                    else { _ = try SubscriptionQRCode.subscription(payloads[0]) }
                } catch { message = (error as? HarborError)?.localizedDescription ?? L10n.text("未能识别图片，请换一张清晰的二维码图片。") }
            }
        }
    }
    private func received(_ value: String) {
        scanning = false
        do { complete(try SubscriptionQRCode.subscription(value)) }
        catch { message = error.localizedDescription }
    }
    private func complete(_ value: String) {
        guard active else { return }
        scanning = false; onSubscription(value); dismiss()
    }
}

private final class QRPreview: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
}

private struct QRCodeCamera: UIViewRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onFailure: onFailure) }
    func makeUIView(context: Context) -> QRPreview {
        let view = QRPreview()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = context.coordinator.session
        context.coordinator.start()
        return view
    }
    func updateUIView(_ uiView: QRPreview, context: Context) {}
    static func dismantleUIView(_ uiView: QRPreview, coordinator: Coordinator) { coordinator.stop() }
    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private static let queue = DispatchQueue(label: "io.picharbor.subscription-camera")
        let session = AVCaptureSession()
        private let onCode: (String) -> Void
        private let onFailure: () -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onCode = onCode; self.onFailure = onFailure
        }
        func start() {
            Self.queue.async { [self] in
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { fail(); return }
                session.beginConfiguration(); session.sessionPreset = .high
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { session.commitConfiguration(); fail(); return }
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); fail(); return }
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration(); session.startRunning()
            }
        }
        func stop() { Self.queue.async { [self] in if session.isRunning { session.stopRunning() } } }
        private func fail() { DispatchQueue.main.async { [self] in onFailure() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !delivered, let value = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            delivered = true; stop(); onCode(value)
        }
    }
}
