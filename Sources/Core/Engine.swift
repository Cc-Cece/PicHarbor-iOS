import Foundation
import SwiftUI

struct HarborError: LocalizedError {
    let code: String
    let detail: String?
    init(_ code: String, detail: String? = nil) { self.code = code; self.detail = detail }
    var errorDescription: String? {
        if code == "PROXY_START_FAILED", let detail, !detail.isEmpty { return L10n.text("代理启动失败：{0}", [detail]) }
        switch code {
        case "LOGIN_REQUIRED": return L10n.text("需要重新登录 Google，或服务端要求额外验证。")
        case "INVALID_CREDENTIAL": return L10n.text("登录凭据无效。")
        case "ACCOUNT_BUSY": return L10n.text("正在连接或切换账号，请等待当前操作完成。")
        case "CLEANUP_BUSY": return L10n.text("正在核验或清理照片，请等待完成后再操作账号。")
        case "NETWORK_ERROR": return L10n.text("网络请求失败，请检查网络后重试。")
        case "PROXY_CONFIG_REQUIRED": return L10n.text("请先导入代理配置。")
        case "QR_SINGLE_NODE": return L10n.text("这是单个节点链接，请使用订阅二维码或手动导入配置文件。")
        case "QR_UNSUPPORTED": return L10n.text("此二维码不是有效的 HTTP 或 HTTPS 订阅链接。")
        case "QR_IMAGE_UNAVAILABLE": return L10n.text("无法读取图片，请选择另一张二维码图片。")
        case "QR_NOT_FOUND": return L10n.text("图片中未找到二维码，请选择清晰、完整的二维码图片。")
        case "PROXY_SUBSCRIPTION_URL": return L10n.text("请输入有效的 HTTP 或 HTTPS 订阅链接。")
        case "PROXY_EMPTY_SUBSCRIPTION": return L10n.text("订阅未提供可用节点，请确认链接支持 Clash Meta 格式。")
        case "PROXY_SUBSCRIPTION_DOWNLOAD": return L10n.text("订阅服务器未返回有效内容，请检查链接后重试。")
        case "PROXY_TASKS_ACTIVE": return L10n.text("请先暂停备份，再更新或切换配置。")
        case "PROXY_PROFILE_LIMIT": return L10n.text("最多保存 20 份配置，请先移除不用的配置。")
        case "PROXY_CONFIG_UNSUPPORTED": return L10n.text("暂不支持此配置，请使用最多 64 个节点的 Clash Meta 完整配置。")
        case "PROXY_START_FAILED": return L10n.text("代理启动失败，请检查节点配置，或导入其他配置重试。")
        case "PROXY_UNAVAILABLE": return L10n.text("允许的连接均不可用，正在等待代理恢复。")
        case "PREVIOUS_BACKUP_NOT_VISIBLE": return L10n.text("已有备份记录，但暂未查询到对应云端内容。会先重新检查，避免重复上传。")
        case "RUNTIME_UNAVAILABLE": return L10n.text("Python 运行环境不可用，请导出诊断报告。")
        case "KEYCHAIN_ERROR": return L10n.text("无法访问安全凭据存储。")
        case "PHOTO_PERMISSION": return L10n.text("请允许访问所选照片，然后重新选择。")
        case "UNSUPPORTED_MEDIA": return L10n.text("暂不支持此媒体格式，原件会保留。")
        case "PAIR_PROTOCOL_UNVERIFIED": return L10n.text("苹果原始资源的云端配对协议尚未验证；原件已保留，不会按两个普通文件上传。")
        case "PAIR_CONFIRMATION_PENDING": return L10n.text("照片与视频的关联请求已提交，正在等待云端确认同一动态项目。继续／重试只核验关联，不会重复提交。")
        case "PAIR_COMMIT_REJECTED": return L10n.text("服务器拒绝了原始资源关联请求。原件与上传响应已保留，请导出诊断并反馈测试方式。")
        case "PAIR_LOOKUP_INVALID": return L10n.text("云端配对查询返回了无法识别的结果，请稍后重试。")
        case "LIVE_KEYFRAME_MISSING": return L10n.text("无法读取 Live Photo 关键帧，已保留原件。")
        case "LIVE_PAIR_MISSING": return L10n.text("无法取得同一版本的完整 Live Photo 资源。")
        case "MOTION_FORMAT_UNSUPPORTED", "MOTION_METADATA_ERROR": return L10n.text("动态照片封装未完成，原件已保留。")
        case "LIVE_CLEANUP_UNVERIFIED": return LiveCleanupPolicy.waitingMessage
        case "LIVE_COMPONENT_UNVERIFIED": return L10n.text("照片和视频已保存，但暂时无法完成动态视频的额外检查。原件已保留，可在空间清理核验中查看检查选项。")
        case "CLEANUP_UNVERIFIED": return L10n.text("完整资源或云端核验未通过，原件会保留。")
        case "CLEANUP_CANCELLED": return L10n.text("检查已停止，原件会保留。")
        case "CLEANUP_POLICY_CHANGED": return L10n.text("清理检查策略已变化，请按新策略重新检查。")
        case "DATABASE_ERROR": return L10n.text("无法读写任务数据库，请检查剩余空间。")
        case "UPLOAD_EXPIRED": return L10n.text("上传授权已过期，可重新准备传输。")
        case "DISK_FULL": return L10n.text("空间不足，无法准备原件或系统后台传输副本。请释放空间后继续。")
        case "WAITING_NETWORK": return L10n.text("正在等待任务所允许的网络。")
        case "REMOTE_MOTION_PENDING": return L10n.text("文件已传输，云端尚未确认为动态照片。稍后重试会重新检查，不重复上传。")
        case "REMOTE_MOTION_NOT_INDEXED": return L10n.text("封装文件已确认，完整云端图库暂未索引到此项目，将自动继续检查。")
        case "REMOTE_MOTION_PROCESSING": return L10n.text("封装文件已确认，谷歌相册仍在处理动态资源，将自动继续检查。")
        case "REMOTE_MOTION_NOT_DYNAMIC": return L10n.text("封装文件已确认，但云端动态标记尚未出现，将自动继续检查。")
        case "REMOTE_MOTION_TRASH_UNKNOWN": return L10n.text("封装文件已确认，但云端未返回可识别的回收站状态，将继续检查。")
        case "REMOTE_MOTION_TRASHED": return L10n.text("云端动态资源已进入回收站，请先在谷歌相册恢复，再重试确认。")
        case "REMOTE_MISSING": return L10n.text("云端未找到相同内容，原件会保留。")
        case "CLOUD_STATE_EXPIRED": return L10n.text("云端状态证据已过期，请重新检查。")
        case "CLOUD_ORIGINAL_UNCONFIRMED": return L10n.text("云端原件状态尚未通过完整核验，原件会保留。")
        case "ORIGINAL_UNAVAILABLE": return L10n.text("云端原件无法访问或大小不符，原件会保留。")
        case "FILE_ACCESS": return L10n.text("无法读取原件或写入暂存文件，请检查空间与照片权限。")
        case "SOURCE_FILE_MISSING": return L10n.text("已导出的暂存原件不存在。请重新准备此任务；不需要删除相册原件。")
        case "UPLOAD_RESPONSE_MISSING", "UPLOAD_RESPONSE_EMPTY": return L10n.text("上传响应文件缺失或为空，尚未完成云端提交。请重新准备此任务。")
        case "UPLOAD_RESPONSE_WRITE", "UPLOAD_RESPONSE_READ": return L10n.text("无法保存或读取上传响应文件。请检查本机空间，再重新准备此任务。")
        case "UPLOAD_RESPONSE_PATH": return L10n.text("上传响应路径不属于当前暂存目录，请重新准备此任务。")
        case "UPLOAD_RESPONSE_TOO_LARGE", "UPLOAD_RESPONSE_INVALID": return L10n.text("上传响应内容无效，尚未完成云端提交。请保持代理可访问 Google 后重试。")
        case "SOURCE_CHANGED": return L10n.text("已导出的暂存文件发生变化。请重新准备此任务；已有云端提交会先按内容核对。")
        case "SOURCE_SETTLING": return L10n.text("照片仍在准备或发生变化，正在等待相册资源稳定；无需重新选择照片。")
        case "SOURCE_SETTLING_LIMIT": return L10n.text("相册资源多次变化，已暂停自动尝试。照片准备完成后点击继续／重试即可，无需重新选择。")
        case "SOURCE_SNAPSHOT_LOCKED": return L10n.text("此任务已有固定的资源版本。请重新准备任务，已有云端结果会先查重。")
        case "ACCOUNT_CHANGED": return L10n.text("账号已变化，请重新连接。")
        case "REMOTE_NOT_VISIBLE": return L10n.text("云端暂未按内容哈希确认，请稍后重新核验。")
        case "WEB_LOGIN_REJECTED": return L10n.text("Google 拒绝了应用内登录。可导入已有 gpmc 凭据验证，其余情况需要调整认证适配。")
        case "INTERRUPTED": return L10n.text("上次传输被中断；重新选择同一照片可查重并重试。")
        default: return L10n.text("操作未完成（{0}），请重试或导出诊断报告。", [String(describing: code)])
        }
    }
}

struct BackupObservation: Codable, Identifiable {
    let id: String
    let account: String
    let name: String
    let sha1: String
    let sha256: String
    let size: Int64
    let remoteKey: String
    let state: String
    let origin: String
    let error: String
    let updated: Int64

    var stateLabel: String {
        switch state {
        case "confirmed": return origin == "content_exists" ? L10n.text("云端已存在 · 已查重") : L10n.text("云端内容已确认")
        case "confirmation_pending": return L10n.text("待云端确认")
        case "uploading": return L10n.text("传输中")
        case "interrupted": return L10n.text("上次传输中断")
        default: return L10n.text("上传失败")
        }
    }
}

@MainActor
final class Engine: ObservableObject {
    @Published var ready = false
    @Published var busy = false
    @Published var account = ""
    @Published var message = L10n.text("正在检查运行环境")
    @Published var phase = ""
    @Published var progress: Double?
    @Published var records: [BackupObservation] = []
    @Published var runtime: [String: String] = [:]
    private let queue = DispatchQueue(label: "io.picharbor.python", qos: .userInitiated)
    private var booted = false
    let home: URL

    init() {
        home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicHarbor", isDirectory: true)
    }

    func boot() async {
        guard !booted else { return }
        booted = true
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            var excluded = home
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: home.path)
            // Durable background transfers may still own these files after relaunch.
            let staging = home.appendingPathComponent("Staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            ready = PythonBridge.start(home.path)
            guard ready else { throw HarborError("RUNTIME_UNAVAILABLE") }
            let info = try await invoke("probe")
            for key in ["python", "tls", "sqlite"] { runtime[key] = info[key] as? String }
            if let credential = try KeychainStore.load() {
                try await connect(credential)
            } else { message = L10n.text("运行环境检查通过，请连接 Google 账号。") }
        } catch { message = error.localizedDescription; if !ready { booted = false } }
    }

    func invoke(_ action: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        let requestID = UUID().uuidString
        var envelope = payload
        if !["probe", "capabilities", "records", "logout"].contains(action) {
            let port: Int
            if let inherited = ProxyContext.port { port = inherited }
            else { port = try await ProxyManager.shared.route().0 }
            envelope["proxy_url"] = port > 0 ? "http://127.0.0.1:\(port)" : ""
        }
        envelope["protocol_version"] = 2; envelope["request_id"] = requestID
        let encoded = try JSONSerialization.data(withJSONObject: envelope)
        let input = String(decoding: encoded, as: UTF8.self)
        let output: String = await withCheckedContinuation { continuation in
            queue.async {
                let result = PythonBridge.call(action, payload: input) { value in
                    // Only whitelisted numeric progress reaches UI; no credentials or URLs.
                    guard let data = value.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    let stage = event["phase"] as? String ?? ""
                    let done = event["completed"] as? Double ?? 0
                    let total = event["total"] as? Double ?? 0
                    Task { @MainActor in
                        self.phase = stage
                        self.progress = total > 0 ? min(1, done / total) : nil
                    }
                }
                continuation.resume(returning: result)
            }
        }
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] ?? [:]
        guard result["protocol_version"] as? Int == 2, result["request_id"] as? String == requestID else { throw HarborError("PROTOCOL_VERSION") }
        guard result["ok"] as? Bool == true else { throw HarborError(result["error"] as? String ?? "ENGINE_ERROR") }
        return result
    }

    private func connect(_ credential: String) async throws {
        account = ""
        records = []
        let result = try await invoke("connect", ["credential": credential])
        guard let saved = result["credential"] as? String, let email = result["account"] as? String else {
            throw HarborError("INVALID_CREDENTIAL")
        }
        do { try KeychainStore.save(saved, account: email) }
        catch { _ = try? await invoke("logout"); throw error }
        account = email
        try await reload()
        message = L10n.text("账号已连接。")
    }

    @discardableResult
    func login(_ credential: String) async -> Bool {
        guard ready else { message = HarborError("RUNTIME_UNAVAILABLE").localizedDescription; return false }
        guard !busy else { message = HarborError("ACCOUNT_BUSY").localizedDescription; return false }
        busy = true
        defer { busy = false }
        do { try await connect(credential); return true }
        catch { message = error.localizedDescription; return false }
    }

    func logout() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try KeychainStore.clear()
            _ = try await invoke("logout")
            account = ""; records = []; message = L10n.text("已退出，设备上的历史记录保留并按账号隔离。")
        } catch { message = error.localizedDescription }
    }

    private func reload() async throws {
        let result = try await invoke("records", ["account": account])
        let data = try JSONSerialization.data(withJSONObject: result["records"] ?? [])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        records = try decoder.decode([BackupObservation].self, from: data)
    }

    func backup(assetID: String, quality: String) async {
        guard ready && !busy && !account.isEmpty else { return }
        busy = true; phase = "exporting"; progress = nil
        defer { busy = false; phase = ""; progress = nil }
        do {
            let photo = try await PhotoSource.exportOriginal(assetID: assetID, staging: home.appendingPathComponent("Staging"))
            defer { try? FileManager.default.removeItem(at: photo.url) }
            _ = try await invoke("upload", ["account": account, "path": photo.url.path, "name": photo.name, "quality": quality])
            try await reload()
            message = records.first?.stateLabel ?? L10n.text("操作完成，请查看记录。")
        } catch { message = error.localizedDescription; try? await reload() }
    }

    func verify(_ record: BackupObservation) async {
        guard !busy && record.account == account else { return }
        busy = true
        defer { busy = false; phase = ""; progress = nil }
        do {
            _ = try await invoke("verify", ["id": record.id, "account": account])
            try await reload()
            message = L10n.text("已重新查询云端，请查看记录状态。")
        } catch { message = error.localizedDescription }
    }

    var diagnostics: String {
        // Intentionally omit email, filenames, hashes, remote IDs, paths and free-form errors.
        let value: [String: Any] = ["app": "PicHarbor A/B", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "runtime_ready": ready, "runtime": runtime, "record_count": records.count,
            "states": records.map(\.state), "errors": records.map(\.error),
            "device_os": ProcessInfo.processInfo.operatingSystemVersionString,
            "bundle_bytes": Self.bundleBytes(), "note": "Hash existence is not cleanup eligibility. Device acceptance is manual."]
        return String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func bundleBytes() -> Int64 {
        guard let files = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            if let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), info.isRegularFile == true {
                total += Int64(info.fileSize ?? 0)
            }
        }
        return total
    }
}
