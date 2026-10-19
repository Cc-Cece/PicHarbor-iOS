import SwiftUI
import Photos

struct JobDetailView: View {
    @ObservedObject private var language = LanguagePreferences.shared
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
                    HStack(spacing: 16) { AssetThumbnail(assetID: job.assetID); JobRow(job: job, showDate: false) }
                    Text(job.settings.quality.title + (job.isLive ? " · " + job.settings.live.title : "")).font(.caption).foregroundStyle(.secondary)
                    Text(job.verificationLevel == "strict" ? L10n.text("已确认动态处理完成") : job.verificationLevel == "standard" ? L10n.text("已确认云端保存") : job.state == .completed ? L10n.text("历史备份记录") : job.settings.requiresStrictConfirmation ? L10n.text("保存后继续等待动态处理") : L10n.text("云端保存确认后完成")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L10n.text("备份流程")) { TaskFlowView(job: job) }
                Section(job.state == .failed || job.state == .attention ? L10n.text("需要处理") : L10n.text("当前状态")) {
                    Text(job.friendlyMessage).foregroundStyle(.secondary)
                    if job.state == .transferring { ProgressView(value: job.progress).accessibilityLabel(L10n.text("上传进度")) }
                    if job.state == .completed { NavigationLink(L10n.text("前往 Google 相册释放空间")) { CleanupView() }.font(.footnote) }
                }
                Section {
                    if job.state == .completed {
                        Button(job.archivedAt == nil ? L10n.text("归档") : L10n.text("取消归档"), systemImage: "archivebox") { Task { await model.archive([id], restoring: job.archivedAt != nil) } }
                    } else if job.state != .cancelled {
                        if job.confirmationOnly {
                            Button(L10n.text("立即检查保存结果"), systemImage: "arrow.clockwise") { Task { await model.resume(id) } }
                            if job.settings.requiresStrictConfirmation != model.settings.requiresStrictConfirmation {
                                Button(L10n.text("按当前核验策略继续")) { Task { await model.pause(id); await model.resume(id, useCurrentConfirmationPolicy: true) } }
                            }
                        }
                        if job.state.active || [.queued, .waiting].contains(job.state) {
                            Button(L10n.text("暂停"), systemImage: "pause") { Task { await model.pause(id) } }
                        } else { Button(L10n.text("继续 / 重试"), systemImage: "play") { Task { await model.resume(id) } } }
                        Button(L10n.text("取消任务"), role: .destructive) { Task { await model.cancel(id) } }
                    }
                    if [.failed, .attention, .paused].contains(job.state) { Button(L10n.text("重新准备此任务")) { reprepare = true } }
                    if job.unfinished { Button(L10n.text("移除未完成任务"), role: .destructive) { remove = true } }
                }
                Section { Button(L10n.text("高级信息"), systemImage: "info.circle") { advanced = true }.accessibilityIdentifier("task.advanced") }
            } else { ContentUnavailableView(L10n.text("任务已不可用"), systemImage: "clock") }
        }.navigationTitle(L10n.text("任务详情")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $advanced) {
            NavigationStack { if let job { TaskAdvancedInformation(job: job) } }
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .confirmationDialog(L10n.text("重新准备此任务？"), isPresented: $reprepare, titleVisibility: .visible) {
            Button(L10n.text("重新读取原件并查重")) { Task { await model.reprepare(id) } }
        } message: { Text(L10n.text("保留原任务设置及批次，重新读取照片并查重。旧任务保留为已取消，本机及云端照片均保留。")) }
        .confirmationDialog(L10n.text("移除此任务？"), isPresented: $remove, titleVisibility: .visible) {
            Button(L10n.text("停止并移除任务"), role: .destructive) { Task { await model.removeUnfinished([id]); dismiss() } }
        } message: { Text(L10n.text("本机及云端照片保留。仍可手动重新备份。")) }
    }
}

struct TaskFlowView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let job: BackupJob
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(job.flowSteps.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 12) {
                    Image(systemName: symbol(index)).font(.title3).foregroundStyle(color(index)).frame(width: 24)
                    Text(title).fontWeight(index == job.flowIndex ? .semibold : .regular)
                    Spacer()
                    if index == job.flowIndex {
                        Text(job.state == .completed ? L10n.text("已完成") : job.state == .paused ? L10n.text("已暂停") : [.failed, .attention].contains(job.state) ? L10n.text("需处理") : job.state == .cancelled ? L10n.text("已取消") : job.state == .waiting ? L10n.text("等待条件") : L10n.text("当前阶段")).font(.caption).foregroundStyle(.secondary)
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
    private func color(_ index: Int) -> Color { job.skippedExisting ? .gray : job.state == .completed ? .green : index <= job.flowIndex ? .blue : .secondary }
}

struct TaskAdvancedInformation: View {
    @EnvironmentObject private var model: HarborModel
    @ObservedObject private var language = LanguagePreferences.shared
    @Environment(\.dismiss) private var dismiss
    let job: BackupJob
    var body: some View {
        List {
            if job.state == .completed {
                Section {
                    Button(L10n.text("使用当前设置创建任务")) { Task {
                        guard job.account == model.account else { return }
                        if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject {
                            await model.enqueue([asset], recreate: true); dismiss()
                        } else { model.notice = L10n.text("无法读取这项照片，请检查相册访问权限。") }
                    } }
                } footer: { Text(L10n.text("已备份的内容会尝试复用，不会修改已有云端项目。")) }
            }
            Section(L10n.text("任务")) {
                LabeledContent(L10n.text("来源"), value: job.origin?.title ?? L10n.text("历史记录，来源未知"))
                LabeledContent(L10n.text("版本策略"), value: job.settings.edits.title)
                LabeledContent(L10n.text("网络"), value: job.settings.wifiOnly ? L10n.text("仅 Wi-Fi") : L10n.text("Wi-Fi 与蜂窝"))
                LabeledContent(L10n.text("检查策略"), value: job.settings.requiresStrictConfirmation ? L10n.text("严格") : L10n.text("标准"))
                LabeledContent(L10n.text("核验结果"), value: job.verificationLevel ?? L10n.text("历史或尚未完成"))
                LabeledContent(L10n.text("创建时间")) { Text(L10n.date(job.created, date: .long, time: .short)) }
                if let stage = job.failureStageTitle { LabeledContent(L10n.text("处理步骤"), value: stage) }
                if !job.error.isEmpty { LabeledContent(L10n.text("错误码"), value: job.error) }
                if let code = job.failureSystemCode { LabeledContent(L10n.text("系统错误"), value: code) }
            }
            Section(L10n.text("确认记录")) {
                if let time = job.pairedAt { LabeledContent(L10n.text("配对确认")) { Text(L10n.date(time, date: .none, time: .short)) } }
                if let time = job.confirmationStartedAt { LabeledContent(L10n.text("开始严格核验")) { Text(L10n.date(time, date: .none, time: .short)) } }
                LabeledContent(L10n.text("严格查询次数"), value: String(job.confirmationChecks ?? 0))
                if let time = job.lastConfirmationAt { LabeledContent(L10n.text("最近查询")) { Text(L10n.date(time, date: .none, time: .short)) } }
                if let seconds = job.lastConfirmationSeconds { LabeledContent(L10n.text("最近耗时"), value: String(format: L10n.text("%.1f 秒"), seconds)) }
                if let time = job.retryAt { LabeledContent(L10n.text("下次尝试")) { Text(L10n.date(time, date: .none, time: .short)) } }
                if let time = job.completedAt { LabeledContent(L10n.text("完成时间")) { Text(L10n.date(time, date: .none, time: .short)) } }
                Text(L10n.text("查询耗时包含协议排队与网络响应。")).font(.caption).foregroundStyle(.secondary)
            }
            if let pairs = job.livePairs, !pairs.isEmpty { Section(L10n.text("配对信息")) {
                ForEach(pairs) { pair in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pair.id == "original" ? L10n.text("原始版本") : L10n.text("编辑后版本"))
                        Text(pair.route == "joint" ? L10n.text("实际路径：联合提交") : pair.route == "reconcile" ? L10n.text("实际路径：先照片后关联视频") : L10n.text("通过已有配对查询"))
                        Text(pair.confirmed ? L10n.text("照片与动态视频哈希已指向同一云端项目") : pair.submitted ? L10n.text("已提交，等待关联确认") : L10n.text("尚未提交关联"))
                    }.font(.footnote)
                }
            } }
            Section(L10n.text("资源 · {0} 项", [String(describing: job.resources.count)])) {
                ForEach(job.resources) { resource in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(resource.name).textSelection(.enabled)
                        Text("\(resource.role) · \(ByteCountFormatter.string(fromByteCount: resource.size, countStyle: .file))").font(.caption)
                        Text(resource.confirmed ? job.hasConfirmedPairs ? L10n.text("资源与配对已确认") : L10n.text("云端内容存在已确认") : L10n.text("尚未确认")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section { ShareLink(item: job.diagnosticText) { Label(L10n.text("导出脱敏诊断"), systemImage: "square.and.arrow.up") } }
        }.navigationTitle(L10n.text("高级信息")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
    }
}
