import SwiftUI

struct CleanupView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var confirm = false
    @State private var selected = Set<String>()
    @State private var filter: CleanupOutcome = .all
    var results: [BackupJob] { model.visibleJobs.filter {
        model.cleanupResults[$0.id] != nil && (filter == .all || model.cleanupOutcomes[$0.id] == filter)
    } }
    var body: some View {
        List {
            Section {
                Label("确认保存，再释放空间", systemImage: "checkmark.shield").font(.headline)
                Text("当前账号有 \(model.cleanupCandidates.count) 张照片或视频可检查。同一照片只列一次，其他照片的备份可以继续。").font(.subheadline).foregroundStyle(.secondary)
                Text(model.settings.allowsUnverifiedLiveCleanup ? "已允许清理尚未完整验证的 Live Photo，照片和视频仍需通过保存检查。" : "尚未完整验证的 Live Photo 会保留。").font(.footnote).foregroundStyle(.secondary)
                NavigationLink("空间清理核验") { CleanupPolicyView() }
                if !model.settings.cloudState || !model.settings.originalAccess {
                    Label("已降低清理核验强度", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    if !model.settings.cloudState { Text("跳过最新云端状态检查").font(.caption).foregroundStyle(.secondary) }
                    if !model.settings.originalAccess { Text("跳过原件访问与大小检查").font(.caption).foregroundStyle(.secondary) }
                }
                if model.cleanupRunning {
                    ProgressView(value: Double(model.cleanupChecked), total: Double(max(1, model.cleanupTotal)))
                    Text(model.cleanupDeleting ? "正在核对所选项目并请求系统删除" : model.cleanupStopping ? "正在停止，当前请求结束后保留检查结果" : "已检查 \(model.cleanupChecked) / \(model.cleanupTotal) 项").font(.caption).foregroundStyle(.secondary)
                    if !model.cleanupDeleting && !model.cleanupStopping { Button("停止检查") { model.cancelCleanupScan() } }
                } else { Button("开始检查") { Task { await model.verifyCleanup() } }.accessibilityIdentifier("cleanup.start") }
            }
            if !model.cleanupResults.isEmpty {
                Section {
                    Picker("检查结果", selection: $filter) { ForEach(CleanupOutcome.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Button("全选已通过") { selected = Set(model.cleanupReady) }.disabled(model.cleanupRunning || model.cleanupReady.isEmpty)
                    if !selected.isEmpty { Button("取消全选") { selected = [] } }
                }
                Section("检查结果") {
                    ForEach(results) { job in
                        HStack {
                            AssetThumbnail(assetID: job.assetID)
                            if model.cleanupReady.contains(job.id) {
                                Button { if selected.contains(job.id) { selected.remove(job.id) } else { selected.insert(job.id) } } label: {
                                    Image(systemName: selected.contains(job.id) ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless).accessibilityLabel(selected.contains(job.id) ? "取消选择此项目" : "选择此项目").disabled(model.cleanupRunning)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.sources.first?.name ?? "备份照片").lineLimit(1)
                                Text(model.cleanupResults[job.id] ?? "").font(.caption).foregroundStyle(model.cleanupReady.contains(job.id) ? .green : .secondary)
                                if job.isLive && !model.settings.allowsUnverifiedLiveCleanup && model.cleanupOutcomes[job.id] == .deferred {
                                    NavigationLink("前往设置") { CleanupPolicyView() }.font(.caption)
                                }
                            }
                            Spacer()
                            if !model.cleanupRunning, let outcome = model.cleanupOutcomes[job.id], [.failed, .deferred].contains(outcome) { Button("重新检查") { Task { await model.verifyCleanup(ids: [job.id]) } }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                }
            }
            if !model.cleanupReady.isEmpty {
                Section {
                    Button("清理所选 \(selected.count) 项", role: .destructive) { confirm = true }.disabled(model.cleanupRunning || selected.isEmpty)
                } footer: { Text("启用 iCloud 照片时，删除会同步到同一图库的其他设备。系统删除授权由你决定。") }
            }
        }.navigationTitle("释放空间").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.cleanupReady) { _, values in selected = CleanupCandidates.remainingSelection(selected, eligible: values) }
        .alert("确认从 iPhone 相册删除？", isPresented: $confirm) {
            Button("核对并请求删除", role: .destructive) { let ids = Array(selected); Task { await model.deleteVerified(ids: ids) } }
            Button("取消", role: .cancel) {}
        } message: { Text("仅请求删除所选且再次核对通过的 \(selected.count) 项。iCloud 照片的删除会同步；谷歌相册中的内容保留。") }
    }
}
