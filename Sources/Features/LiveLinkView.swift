import SwiftUI
import Photos
import PhotosUI
import AVFoundation

struct LiveLinkView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @StateObject private var link = LiveLinkController()
    @State private var scan = false
    @State private var host = ""
    @State private var port = ""
    @State private var fingerprint = ""
    @State private var code = ""
    @State private var scanned = ""
    @State private var filling = false
    @State private var allowCloud = false

    private var scopeCount: Int { model.library.scope(model.settings).count }

    var body: some View {
        Form {
            if let saved = link.saved {
                Section(L10n.text("已保存的电脑")) {
                    LabeledContent(L10n.text("电脑"), value: saved.name)
                    LabeledContent(L10n.text("地址"), value: "\(saved.host):\(saved.port)")
                    LabeledContent(L10n.text("证书前 16 位"), value: String(saved.fingerprint.prefix(16)))
                    Button(L10n.text("连接已保存的电脑")) { link.connectSaved() }.disabled(link.busy)
                    Button(L10n.text("忘记这台电脑"), role: .destructive) { link.forget() }.disabled(link.busy)
                }
            }
            Section {
                Button { scan = true } label: { Label(L10n.text("扫描电脑二维码"), systemImage: "qrcode.viewfinder") }
                    .disabled(link.busy)
                Text(L10n.text("扫描电脑上的二维码，或手动输入地址和配对码。"))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(L10n.text("仅在同一局域网内直接传输，不经过互联网。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                TextField(L10n.text("地址"), text: $host)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                TextField(L10n.text("端口"), text: $port).keyboardType(.numberPad)
                TextField(L10n.text("证书前 16 位"), text: $fingerprint)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(L10n.text("配对码"), text: $code).keyboardType(.numberPad)
            }
            Section {
                Text(L10n.text("将发送当前照片范围，不需要 Google 账号。"))
                    .font(.footnote).foregroundStyle(.secondary)
                Text(L10n.text("当前范围 {0} 项", [String(scopeCount)]))
                Toggle(L10n.text("允许从 iCloud 下载"), isOn: $allowCloud).disabled(link.busy)
                if model.library.status != .authorized && model.library.status != .limited {
                    Button(L10n.text("允许访问相册")) { Task { await model.library.authorize() } }
                }
                if link.skipped > 0 {
                    Text(L10n.text("已跳过 {0} 项仅保存在 iCloud 的原件", [String(link.skipped)]))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L10n.text("发送期间请保持 PicHarbor 在前台。锁屏后传输会停止，因为后台传输无法校验这台电脑的自签名证书。下一批也需要打开 PicHarbor。"))
            }
            Section {
                if link.busy {
                    ProgressView(value: link.fraction) { Text(link.status) }
                    if !link.currentFile.isEmpty { Text(link.currentFile).font(.caption).lineLimit(1).truncationMode(.middle) }
                    Button(L10n.text("停止发送"), role: .cancel) { link.stop() }
                } else {
                    Button { start() } label: { Label(L10n.text("开始发送"), systemImage: "arrow.up.circle.fill").font(.headline) }
                        .accessibilityIdentifier("link.send")
                }
                if link.started {
                    Text(L10n.text("已发送 {0}，电脑已有 {1}，跳过 {2}。", [String(link.sentCount), String(link.hadCount), String(link.skipped)]))
                        .font(.footnote).foregroundStyle(.secondary)
                    if link.failedCount > 0 {
                        Text(L10n.text("未能发送 {0} 项。", [String(link.failedCount)])).font(.footnote)
                    }
                }
                if !link.message.isEmpty { Text(link.message).font(.footnote) }
                if !link.busy, link.status == L10n.text("发送完成") {
                    Text(L10n.text("发送完成")).font(.footnote)
                }
            }
        }
        .navigationTitle(L10n.text("传到这台电脑"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { link.reload() }
        .onDisappear { if !scan { link.stop() } }
        .onChange(of: fingerprint) { _, value in
            guard !filling else { return }
            let prefix = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !scanned.isEmpty, !scanned.lowercased().hasPrefix(prefix) { scanned = "" }
        }
        .sheet(isPresented: $scan) {
            LiveLinkScanner { target in
                filling = true
                host = target.host
                port = String(target.port)
                code = target.code
                if case .full(let value) = target.pin {
                    scanned = value
                    fingerprint = String(value.prefix(16))
                }
                filling = false
            }
        }
    }

    private func start() {
        if scopeCount == 0 {
            link.message = L10n.text("没有可发送的照片或视频。")
            return
        }
        link.send(host: host, port: port, prefix: fingerprint, code: code, scanned: scanned.isEmpty ? nil : scanned,
                  assets: model.library.scope(model.settings), allowCloud: allowCloud)
    }
}

private struct LiveLinkScanner: View {
    let onCode: (LiveLinkTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraAllowed = false
    @State private var checkedPermission = false
    @State private var cameraID = UUID()
    @State private var scanning = true
    @State private var message = ""
    @State private var selectedImage: PhotosPickerItem?
    @State private var readingImage = false
    @State private var active = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if cameraAllowed && scanning && scenePhase == .active && !readingImage {
                        QRCodeCamera(onCode: received, onFailure: {
                            message = L10n.text("相机暂不可用，可从相册选择二维码。")
                            scanning = false
                        })
                        .id(cameraID).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel(L10n.text("将电脑上的连接二维码放入取景框"))
                    } else {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 80)).foregroundStyle(.secondary).frame(height: 200)
                    }
                    Text(L10n.text("扫描电脑上的二维码，或手动输入地址和配对码。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.callout) }
                    if readingImage { ProgressView(L10n.text("正在识别二维码…")) }
                    PhotosPicker(selection: $selectedImage, matching: .images, photoLibrary: .shared()) {
                        Label(L10n.text("从相册选择二维码"), systemImage: "photo")
                    }.disabled(readingImage)
                    if cameraAllowed && !scanning {
                        Button(L10n.text("继续扫描")) { message = ""; cameraID = UUID(); scanning = true }
                    } else if checkedPermission && !cameraAllowed {
                        Button(L10n.text("前往系统设置")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }.padding()
            }
            .navigationTitle(L10n.text("扫描电脑二维码"))
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
            readingImage = true
            scanning = false
            message = ""
            Task { @MainActor in
                defer { readingImage = false; selectedImage = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw HarborError("QR_IMAGE_UNAVAILABLE") }
                    let payloads = try await Task.detached(priority: .userInitiated) { try SubscriptionQRCode.messages(in: data) }.value
                    guard !payloads.isEmpty else { throw HarborError("QR_NOT_FOUND") }
                    guard let target = payloads.compactMap(LiveLinkCheck.parseQR).first else { throw LiveLinkFailure.qr }
                    complete(target)
                } catch {
                    message = (error as? LocalizedError)?.errorDescription ?? L10n.text("未能识别图片，请换一张清晰的二维码图片。")
                }
            }
        }
    }

    private func received(_ value: String) {
        scanning = false
        guard let target = LiveLinkCheck.parseQR(value) else {
            message = L10n.text("这不是连接电脑的二维码。")
            return
        }
        complete(target)
    }

    private func complete(_ target: LiveLinkTarget) {
        guard active else { return }
        scanning = false
        onCode(target)
        dismiss()
    }
}
