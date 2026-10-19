import SwiftUI
import Photos

struct JobDetailView: View {
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var advanced = false
    @State private var reprepare = false
    @State private var remove = false
    var job: BackupJob? { model.jobs.first { $0.id == id } }
    var body: some View {
        List {
            if let job {
                Section {
                    HStack(spacing: 16) { TaskThumbnail(assetID: job.assetID); JobRow(job: job) }
                    Text(job.settings.quality.title + (job.isLive ? " · " + job.settings.live.title : "")).font(.caption).foregroundStyle(.secondary)
                    Text(job.verificationLevel == "strict" ? "严格核验通过" : job.verificationLevel == "standard" ? "标准核验通过" : job.settings.requiresStrictConfirmation ? "本任务使用严格核验" : "本任务使用标准核验").font(.caption).foregroundStyle(.secondary)
                }
                Section("备份流程") { TaskFlowView(job: job) }
                Section(job.state == .failed || job.state == .attention ? "需要处理" : "当前状态") {
                    Text(job.friendlyMessage).foregroundStyle(.secondary)
                    if job.state == .transferring { ProgressView(value: job.progress).accessibilityLabel("上传进度") }
                    if job.state == .completed && job.isLive { Text("Live Photo 完整资源取回验证开放前，本机原件会保留。").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    if job.state == .completed {
                        Button("按当前设置重新备份") { Task {
                            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject { await model.enqueue([asset], force: true) }
                            else { model.notice = "无法读取这项照片，请检查相册访问权限。" }
                        } }
                    } else if job.state != .cancelled {
                        if job.confirmationOnly {
                            Button("立即检查保存结果", systemImage: "arrow.clockwise") { Task { await model.resume(id) } }
                            if job.settings.requiresStrictConfirmation != model.settings.requiresStrictConfirmation {
                                Button("按当前核验策略继续") { Task { await model.pause(id); await model.resume(id, useCurrentConfirmationPolicy: true) } }
                            }
                        }
                        if job.state.active || [.queued, .waiting].contains(job.state) {
                            Button("暂停", systemImage: "pause") { Task { await model.pause(id) } }
                        } else { Button("继续 / 重试", systemImage: "play") { Task { await model.resume(id) } } }
                        Button("取消任务", role: .destructive) { Task { await model.cancel(id) } }
                    }
                    if [.failed, .attention, .paused].contains(job.state) { Button("重新准备此任务") { reprepare = true } }
                    if job.unfinished { Button("移除未完成任务", role: .destructive) { remove = true } }
                }
                Section { Button("高级信息", systemImage: "info.circle") { advanced = true }.accessibilityIdentifier("task.advanced") }
            } else { ContentUnavailableView("任务已不可用", systemImage: "clock") }
        }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $advanced) {
            NavigationStack { if let job { TaskAdvancedInformation(job: job) } }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog("重新准备此任务？", isPresented: $reprepare, titleVisibility: .visible) {
            Button("重新读取原件并查重") { Task { await model.reprepare(id) } }
        } message: { Text("保留原任务设置及批次，重新读取照片并查重。旧任务保留为已取消，本机及云端照片均保留。") }
        .confirmationDialog("移除此任务？", isPresented: $remove, titleVisibility: .visible) {
            Button("停止并移除任务", role: .destructive) { Task { await model.removeUnfinished([id]); dismiss() } }
        } message: { Text("本机及云端照片保留。仍可手动重新备份。") }
    }
}

struct TaskFlowView: View {
    let job: BackupJob
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(job.flowSteps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 12) {
                    Image(systemName: symbol(index)).font(.title3).foregroundStyle(color(index)).frame(width: 24)
                    Text(title).fontWeight(index == job.flowIndex ? .semibold : .regular)
                    Spacer()
                    if index == job.flowIndex {
                        Text(job.state == .completed ? "已完成" : job.state == .paused ? "已暂停" : [.failed, .attention].contains(job.state) ? "需处理" : job.state == .cancelled ? "已取消" : job.state == .waiting ? "等待条件" : "当前阶段").font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.padding(.vertical, 8).accessibilityIdentifier("task.flow")
    }
    private func symbol(_ index: Int) -> String {
        if index < job.flowIndex || job.state == .completed { return "checkmark.circle.fill" }
        if index == job.flowIndex { return [.failed, .attention].contains(job.state) ? "exclamationmark.circle.fill" : job.state == .paused ? "pause.circle.fill" : "circle.inset.filled" }
        return "circle"
    }
    private func color(_ index: Int) -> Color { job.state == .completed ? .green : index <= job.flowIndex ? .blue : .secondary }
}

struct TaskAdvancedInformation: View {
    @Environment(\.dismiss) private var dismiss
    let job: BackupJob
    var body: some View {
        List {
            Section("任务") {
                LabeledContent("来源", value: job.origin?.title ?? "历史记录，来源未知")
                LabeledContent("版本策略", value: job.settings.edits.title)
                LabeledContent("网络", value: job.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 与蜂窝")
                LabeledContent("检查策略", value: job.settings.requiresStrictConfirmation ? "严格" : "标准")
                LabeledContent("核验结果", value: job.verificationLevel ?? "历史或尚未完成")
                LabeledContent("创建时间") { Text(job.created, style: .time) }
                if let stage = job.failureStageTitle { LabeledContent("处理步骤", value: stage) }
                if !job.error.isEmpty { LabeledContent("错误码", value: job.error) }
                if let code = job.failureSystemCode { LabeledContent("系统错误", value: code) }
            }
            Section("确认记录") {
                if let time = job.pairedAt { LabeledContent("配对确认") { Text(time, style: .time) } }
                if let time = job.confirmationStartedAt { LabeledContent("开始严格核验") { Text(time, style: .time) } }
                LabeledContent("严格查询次数", value: String(job.confirmationChecks ?? 0))
                if let time = job.lastConfirmationAt { LabeledContent("最近查询") { Text(time, style: .time) } }
                if let seconds = job.lastConfirmationSeconds { LabeledContent("最近耗时", value: String(format: "%.1f 秒", seconds)) }
                if let time = job.retryAt { LabeledContent("下次尝试") { Text(time, style: .time) } }
                if let time = job.completedAt { LabeledContent("完成时间") { Text(time, style: .time) } }
                Text("查询耗时包含协议排队与网络响应。").font(.caption).foregroundStyle(.secondary)
            }
            if let pairs = job.livePairs, !pairs.isEmpty { Section("配对信息") {
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pair.id == "original" ? "原始版本" : "编辑后版本")
                        Text(pair.route == "joint" ? "实际路径：联合提交" : pair.route == "reconcile" ? "实际路径：先照片后关联视频" : "通过已有配对查询")
                        Text(pair.confirmed ? "照片与动态视频哈希已指向同一云端项目" : pair.submitted ? "已提交，等待关联确认" : "尚未提交关联")
                    }.font(.footnote)
                }
            } }
            Section("资源 · \(job.resources.count) 项") {
                ForEach(job.resources) { resource in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resource.name).textSelection(.enabled)
                        Text("\(resource.role) · \(ByteCountFormatter.string(fromByteCount: resource.size, countStyle: .file))").font(.caption)
                        Text(resource.confirmed ? job.hasConfirmedPairs ? "资源与配对已确认" : "云端内容存在已确认" : "尚未确认").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section { ShareLink(item: job.diagnosticText) { Label("导出脱敏诊断", systemImage: "square.and.arrow.up") } }
        }.navigationTitle("高级信息").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

private struct TaskThumbnail: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var request: PHImageRequestID?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").font(.title).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.frame(width: 64, height: 64).background(Color(uiColor: .secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            guard request == nil, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return }
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false
            request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: options) { value, _ in DispatchQueue.main.async { image = value } }
        }.onDisappear { if let request { PHImageManager.default().cancelImageRequest(request) }; request = nil }
        .accessibilityHidden(true)
    }
}
