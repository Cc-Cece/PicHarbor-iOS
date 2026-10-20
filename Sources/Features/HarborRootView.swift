import SwiftUI
import Photos

struct HarborRootView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @StateObject private var model = HarborModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcome = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { LibraryView() }.tabItem { Label(L10n.text("照片"), systemImage: "photo.on.rectangle") }.tag(0)
            NavigationStack { BackupDashboard() }.tabItem { Label(L10n.text("备份"), systemImage: "icloud.and.arrow.up") }.tag(1)
            NavigationStack { ActivityView() }.tabItem { Label(L10n.text("活动"), systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { HarborSettingsView() }.tabItem { Label(L10n.text("设置"), systemImage: "gearshape") }.tag(3)
        }
        .environmentObject(model)
        .environment(\.locale, L10n.locale)
        .modifier(PhotoKitExportProbe(model: model))
        .tint(.blue)
        .preferredColorScheme(model.settings.appearance == "dark" ? .dark : model.settings.appearance == "light" ? .light : nil)
        .safeAreaInset(edge: .top) {
          VStack(spacing: 0) {
            if model.recoveryRequired {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.text("备份队列已安全保留"), systemImage: "pause.circle")
                    Text(L10n.text("为避免恢复大量任务时卡顿，已暂缓自动备份。可以先查看任务，再继续备份。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L10n.text("继续备份")) { Task { await model.continueQueueRecovery() } }
                        .disabled(model.switching || !model.initialized)
                        .accessibilityIdentifier("queue.recover")
                }.frame(maxWidth: .infinity, alignment: .leading).padding().background(.regularMaterial)
            }
            if model.enqueueing {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(model.enqueueProcessed), total: Double(max(1, model.enqueueTotal)))
                    HStack {
                        Text(L10n.text("正在加入备份队列 · {0}/{1}", [String(model.enqueueProcessed), String(model.enqueueTotal)]))
                        Spacer()
                        Button(L10n.text("停止加入")) { model.stopAddingTasks() }.accessibilityIdentifier("queue.stopAdding")
                    }.font(.caption)
                }.padding().background(.regularMaterial)
            }
            if L10n.message(model.notice) == L10n.text("已加入备份队列。") {
                HStack {
                    Label(L10n.text("已加入备份队列 · {0} 项", [String(describing: model.queueNoticeCount)]), systemImage: "checkmark.circle.fill").font(.subheadline)
                    Spacer()
                    Button(L10n.text("查看活动")) { model.notice = ""; selectedTab = 2 }
                    Button { model.notice = "" } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("关闭备份提示"))
                }.padding().background(.regularMaterial)
            }
          }
        }
        .task(id: model.queueNoticeID) {
            guard L10n.message(model.notice) == L10n.text("已加入备份队列。") else { return }
            let identifier = model.queueNoticeID
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if identifier == model.queueNoticeID && L10n.message(model.notice) == L10n.text("已加入备份队列。") { model.notice = "" }
        }
        .task {
            await model.boot()
            #if DEBUG
            if model.installTaskPresentationFixture() { selectedTab = 2; return }
            #endif
            welcome = model.initialized && model.account.isEmpty && selectedTab == 0
        }
        .sheet(isPresented: $welcome) { NavigationStack { ConnectionView() }.environmentObject(model) }
        .alert("PicHarbor", isPresented: Binding(get: { !model.notice.isEmpty && L10n.message(model.notice) != L10n.text("已加入备份队列。") }, set: { if !$0 { model.notice = "" } })) {
            Button(L10n.text("好")) { model.notice = "" }
        } message: { Text(L10n.message(model.notice)) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.library.refresh(); await model.pump() } }
            if phase == .background { HarborAppDelegate.schedule() }
        }
    }
}

struct BackupDashboard: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var confirm = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: model.activeCount > 0 ? "icloud.and.arrow.up.fill" : "checkmark.icloud.fill")
                        .font(.system(size: 44)).foregroundStyle(.blue).accessibilityHidden(true)
                    Text(model.activeCount > 0 ? L10n.text("备份进行中") : L10n.text("让回忆安心留存")).font(.title2.bold())
                    Text(model.account.isEmpty ? L10n.text("连接 Google 账号，开始备份你的照片与视频。") : model.account).font(.subheadline).foregroundStyle(.secondary)
                    if model.account.isEmpty { NavigationLink(L10n.text("连接 Google 账号")) { ConnectionView() } }
                    HStack {
                        metric(L10n.text("已备份"), model.completedCount)
                        Spacer()
                        metric(L10n.text("待完成"), model.activeCount)
                        Spacer()
                        metric(L10n.text("可访问"), model.library.assets.count)
                    }
                    if model.activeCount > 0 { BackupTransferMetrics() }
                    PipelineActivitySummary()
                }.padding(.vertical, 12)
            }
            Section {
                Button { confirm = true } label: { Label(L10n.text("备份当前范围"), systemImage: "arrow.up.circle.fill").font(.headline) }
                    .disabled(model.account.isEmpty || !model.initialized || model.enqueueing || model.recoveryRequired)
                NavigationLink { BackupScopeView() } label: { Label(L10n.text("备份范围"), systemImage: "rectangle.stack") }
                NavigationLink { BackupPreferencesView() } label: { Label(L10n.text("备份偏好"), systemImage: "slider.horizontal.3") }
            }
            Section {
                NavigationLink { CleanupView() } label: { Label(L10n.text("释放 iPhone 空间"), systemImage: "internaldrive") }
            } footer: { Text(L10n.text("通过 Google 相册释放本机空间。后台备份由系统安排，打开 PicHarbor 可继续推进。")) }
            Section(L10n.text("当前设置")) {
                LabeledContent(L10n.text("上传画质"), value: model.settings.quality.title)
                LabeledContent("Live Photo", value: model.settings.live.title)
                LabeledContent(L10n.text("自动备份"), value: model.settings.automatic ? L10n.text("已开启") : L10n.text("未开启"))
                LabeledContent(L10n.text("网络"), value: model.settings.wifiOnly ? L10n.text("仅 Wi-Fi") : L10n.text("Wi-Fi 与蜂窝"))
                if !model.network.connected { Label(L10n.text("等待网络连接"), systemImage: "wifi.slash").foregroundStyle(.secondary) }
                else if model.settings.wifiOnly && !model.network.wifi { Label(L10n.text("等待 Wi-Fi"), systemImage: "wifi").foregroundStyle(.secondary) }
            }
            if !model.engine.ready { Section { Text(L10n.message(model.engine.message)).foregroundStyle(.secondary) } }
        }
        .navigationTitle(L10n.text("备份"))
        .confirmationDialog(L10n.text("确认备份范围与设置"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L10n.text("开始备份")) { Task { await model.enqueue(model.library.scope(model.settings)) } }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("{0} 项 · {1}\n{2} · {3}", [String(describing: model.library.scope(model.settings).count), String(describing: model.settings.quality.title), String(describing: model.settings.live.title), String(describing: model.settings.edits.title)])) }
    }
    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value.formatted()).font(.title2.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}

private struct BackupTransferMetrics: View {
    @EnvironmentObject private var model: HarborModel
    @ObservedObject private var language = LanguagePreferences.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let summary = model.backupTransferSummary()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 24) {
                    value(L10n.text("当前速度"), speed(summary.bytesPerSecond))
                    value(L10n.text("剩余大小"), remaining(summary))
                }
                Text(summary.unknownSizeCount > 0
                     ? L10n.text("另有 {0} 项待计算大小。", [String(summary.unknownSizeCount)])
                     : summary.uploadFinished ? L10n.text("等待确认保存") : L10n.text("仅统计尚未上传的内容。"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("backup.transferMetrics")
    }
    private func value(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.subheadline.bold()).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func speed(_ bytes: Double?) -> String {
        guard let bytes else { return L10n.text("计算中…") }
        guard bytes > 0, bytes.isFinite else { return "0 KB/s" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(bytes, Double(Int64.max / 2))), countStyle: .file) + "/s"
    }
    private func remaining(_ summary: BackupTransferSummary) -> String {
        if summary.remainingBytes == 0 && summary.unknownSizeCount > 0 { return L10n.text("计算中…") }
        let size = summary.remainingBytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: summary.remainingBytes, countStyle: .file)
        return summary.unknownSizeCount > 0 ? L10n.text("至少 {0}", [size]) : size
    }
}

struct JobRow: View {
    @EnvironmentObject private var model: HarborModel
    @ObservedObject private var language = LanguagePreferences.shared
    let job: BackupJob
    var showDate = true
    @State private var filename = false
    var name: String { job.sources.first?.name ?? (job.isLive ? "Live Photo" : L10n.text("照片或视频")) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.statusSymbol)
                .font(.title2).foregroundStyle(job.skippedExisting ? .gray : job.state == .completed ? .green : .blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if showDate { Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    Button { filename = true } label: { Text(name).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).accessibilityIdentifier("task.filename").layoutPriority(1)
                        .contextMenu { Button(L10n.text("复制文件名"), systemImage: "doc.on.doc") { UIPasteboard.general.string = name } }
                }
                if showDate { Text(L10n.date(job.created)).font(.caption2).foregroundStyle(.secondary) }
                Text(job.albumsPending ? L10n.text("已备份 · 等待相簿同步") : job.displayStatus).font(.caption).foregroundStyle(.secondary)
                if job.state == .transferring { ProgressView(value: model.transferProgress[job.id] ?? job.progress).accessibilityLabel(L10n.text("上传进度")) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 4)
        .sheet(isPresented: $filename) {
            NavigationStack {
                ScrollView { Text(name).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle(L10n.text("完整文件名")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { filename = false } } }
            }.presentationDetents([.medium, .large])
        }
    }
}
