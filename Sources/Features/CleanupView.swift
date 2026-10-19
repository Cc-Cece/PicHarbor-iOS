import SwiftUI

struct CleanupView: View {
    @ObservedObject private var language = LanguagePreferences.shared
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
                Label(L10n.text("确认保存，再释放空间"), systemImage: "checkmark.shield").font(.headline)
                Text(L10n.text("当前账号有 {0} 张照片或视频可检查。同一照片只列一次，其他照片的备份可以继续。", [String(describing: model.cleanupCandidates.count)])).font(.subheadline).foregroundStyle(.secondary)
                Text(model.settings.allowsUnverifiedLiveCleanup ? L10n.text("已允许清理尚未完整验证的 Live Photo，照片和视频仍需通过保存检查。") : L10n.text("尚未完整验证的 Live Photo 会保留。")).font(.footnote).foregroundStyle(.secondary)
                NavigationLink(L10n.text("空间清理核验")) { CleanupPolicyView() }
                if !model.settings.cloudState || !model.settings.originalAccess {
                    Label(L10n.text("已降低清理核验强度"), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    if !model.settings.cloudState { Text(L10n.text("跳过最新云端状态检查")).font(.caption).foregroundStyle(.secondary) }
                    if !model.settings.originalAccess { Text(L10n.text("跳过原件访问与大小检查")).font(.caption).foregroundStyle(.secondary) }
                }
                if model.cleanupRunning {
                    ProgressView(value: Double(model.cleanupChecked), total: Double(max(1, model.cleanupTotal)))
                    Text(model.cleanupDeleting ? L10n.text("正在核对所选项目并请求系统删除") : model.cleanupStopping ? L10n.text("正在停止，当前请求结束后保留检查结果") : L10n.text("已检查 {0} / {1} 项", [String(describing: model.cleanupChecked), String(describing: model.cleanupTotal)])).font(.caption).foregroundStyle(.secondary)
                    if !model.cleanupDeleting && !model.cleanupStopping { Button(L10n.text("停止检查")) { model.cancelCleanupScan() } }
                } else { Button(L10n.text("开始检查")) { Task { await model.verifyCleanup() } }.accessibilityIdentifier("cleanup.start") }
            }
            if !model.cleanupResults.isEmpty {
                Section {
                    Picker(L10n.text("检查结果"), selection: $filter) { ForEach(CleanupOutcome.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    Button(L10n.text("全选已通过")) { selected = Set(model.cleanupReady) }.disabled(model.cleanupRunning || model.cleanupReady.isEmpty)
                    if !selected.isEmpty { Button(L10n.text("取消全选")) { selected = [] } }
                }
                Section(L10n.text("检查结果")) {
                    ForEach(results) { job in
                        HStack {
                            AssetThumbnail(assetID: job.assetID)
                            if model.cleanupReady.contains(job.id) {
                                Button { if selected.contains(job.id) { selected.remove(job.id) } else { selected.insert(job.id) } } label: {
                                    Image(systemName: selected.contains(job.id) ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.borderless).accessibilityLabel(selected.contains(job.id) ? L10n.text("取消选择此项目") : L10n.text("选择此项目")).disabled(model.cleanupRunning)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.sources.first?.name ?? L10n.text("备份照片")).lineLimit(1)
                                Text(L10n.message(model.cleanupResults[job.id] ?? "")).font(.caption).foregroundStyle(model.cleanupReady.contains(job.id) ? .green : .secondary)
                                if job.isLive && !model.settings.allowsUnverifiedLiveCleanup && model.cleanupOutcomes[job.id] == .deferred {
                                    NavigationLink(L10n.text("前往设置")) { CleanupPolicyView() }.font(.caption)
                                }
                            }
                            Spacer()
                            if !model.cleanupRunning, let outcome = model.cleanupOutcomes[job.id], [.failed, .deferred].contains(outcome) { Button(L10n.text("重新检查")) { Task { await model.verifyCleanup(ids: [job.id]) } }.buttonStyle(.borderless).font(.caption) }
                        }
                    }
                }
            }
            if !model.cleanupReady.isEmpty {
                Section {
                    Button(L10n.text("清理所选 {0} 项", [String(describing: selected.count)]), role: .destructive) { confirm = true }.disabled(model.cleanupRunning || selected.isEmpty)
                } footer: { Text(L10n.text("启用 iCloud 照片时，删除会同步到同一图库的其他设备。系统删除授权由你决定。")) }
            }
        }.navigationTitle(L10n.text("释放空间")).navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.cleanupReady) { _, values in selected = CleanupCandidates.remainingSelection(selected, eligible: values) }
        .alert(L10n.text("确认从 iPhone 相册删除？"), isPresented: $confirm) {
            Button(L10n.text("核对并请求删除"), role: .destructive) { let ids = Array(selected); Task { await model.deleteVerified(ids: ids) } }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("仅请求删除所选且再次核对通过的 {0} 项。iCloud 照片的删除会同步；谷歌相册中的内容保留。", [String(describing: selected.count)])) }
    }
}
