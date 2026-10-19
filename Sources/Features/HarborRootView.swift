import SwiftUI
import Photos

struct HarborRootView: View {
    @StateObject private var model = HarborModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcome = false
    @State private var selectedTab = 0
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { LibraryView() }.tabItem { Label("照片", systemImage: "photo.on.rectangle") }.tag(0)
            NavigationStack { BackupDashboard() }.tabItem { Label("备份", systemImage: "icloud.and.arrow.up") }.tag(1)
            NavigationStack { ActivityView() }.tabItem { Label("活动", systemImage: "clock.arrow.circlepath") }.tag(2)
            NavigationStack { HarborSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        .environmentObject(model)
        .modifier(PhotoKitExportProbe(model: model))
        .tint(.blue)
        .preferredColorScheme(model.settings.appearance == "dark" ? .dark : model.settings.appearance == "light" ? .light : nil)
        .safeAreaInset(edge: .top) {
            if model.notice == "已加入备份队列。" {
                HStack {
                    Label("已加入备份队列", systemImage: "checkmark.circle.fill").font(.subheadline)
                    Spacer()
                    Button("查看活动") { model.notice = ""; selectedTab = 2 }
                    Button { model.notice = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭备份提示")
                }.padding().background(.regularMaterial)
            }
        }
        .task { await model.boot(); welcome = model.initialized && model.account.isEmpty && selectedTab == 0 }
        .sheet(isPresented: $welcome) { NavigationStack { ConnectionView() }.environmentObject(model) }
        .alert("PicHarbor", isPresented: Binding(get: { !model.notice.isEmpty && model.notice != "已加入备份队列。" }, set: { if !$0 { model.notice = "" } })) {
            Button("好") { model.notice = "" }
        } message: { Text(model.notice) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.library.refresh(); await model.pump() } }
            if phase == .background { HarborAppDelegate.schedule() }
        }
    }
}

struct BackupDashboard: View {
    @EnvironmentObject private var model: HarborModel
    @State private var confirm = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: model.activeCount > 0 ? "icloud.and.arrow.up.fill" : "checkmark.icloud.fill")
                        .font(.system(size: 44)).foregroundStyle(.blue).accessibilityHidden(true)
                    Text(model.activeCount > 0 ? "备份进行中" : "让回忆安心留存").font(.title2.bold())
                    Text(model.account.isEmpty ? "连接 Google 账号，开始备份你的照片与视频。" : model.account).font(.subheadline).foregroundStyle(.secondary)
                    if model.account.isEmpty { NavigationLink("连接 Google 账号") { ConnectionView() } }
                    HStack {
                        metric("已备份", model.completedCount)
                        Spacer()
                        metric("待完成", model.activeCount)
                        Spacer()
                        metric("可访问", model.library.assets.count)
                    }
                }.padding(.vertical, 12)
            }
            Section {
                Button { confirm = true } label: { Label("备份当前范围", systemImage: "arrow.up.circle.fill").font(.headline) }
                    .disabled(model.account.isEmpty || !model.initialized)
                NavigationLink { BackupScopeView() } label: { Label("备份范围", systemImage: "rectangle.stack") }
                NavigationLink { BackupPreferencesView() } label: { Label("备份偏好", systemImage: "slider.horizontal.3") }
            }
            Section("当前设置") {
                LabeledContent("上传画质", value: model.settings.quality.title)
                LabeledContent("Live Photo", value: model.settings.live.title)
                LabeledContent("自动备份", value: model.settings.automatic ? "已开启" : "未开启")
                LabeledContent("网络", value: model.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 与蜂窝")
                if !model.network.connected { Label("等待网络连接", systemImage: "wifi.slash").foregroundStyle(.secondary) }
                else if model.settings.wifiOnly && !model.network.wifi { Label("等待 Wi-Fi", systemImage: "wifi").foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink { CleanupView() } label: { Label("释放 iPhone 空间", systemImage: "internaldrive") }
            } footer: { Text("仅清理核验通过且由你确认的本地照片。后台任务由系统安排，打开应用可继续推进。") }
            if !model.engine.ready { Section { Text(model.engine.message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("备份")
        .confirmationDialog("确认备份范围与设置", isPresented: $confirm, titleVisibility: .visible) {
            Button("开始备份") { Task { await model.enqueue(model.library.scope(model.settings)) } }
            Button("取消", role: .cancel) {}
        } message: { Text("\(model.library.scope(model.settings).count) 项 · \(model.settings.quality.title)\n\(model.settings.live.title) · \(model.settings.edits.title)") }
    }
    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(value.formatted()).font(.title2.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
}

struct ActivityView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var filter = "all"
    @AppStorage("activity.grouping") private var grouping = "batch"
    @State private var removal = Set<String>()
    @State private var confirmRemoval = false
    var filtered: [BackupJob] { model.visibleJobs.filter { filter == "all" || (filter == "done" ? $0.state == .completed : $0.unfinished && $0.state != .cancelled) } }
    var body: some View {
        List {
            Section {
                Picker("任务", selection: $filter) { Text("全部").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("done") }.pickerStyle(.segmented)
            }
            if filtered.isEmpty { ContentUnavailableView("暂无备份活动", systemImage: "clock", description: Text("备份任务和处理结果会显示在这里。")) }
            if grouping == "none" {
                ForEach(filtered) { job in activityRow(job) }
            } else {
                ForEach(ActivityGroup.groups(filtered, byBatch: grouping == "batch")) { group in
                    Section {
                        ForEach(group.jobs) { job in activityRow(job) }
                    } header: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.origin?.title ?? "历史任务（未记录来源）")
                            if grouping == "batch" {
                                if group.jobs.first?.batchID != nil { Text(group.date, format: .dateTime.month().day().hour().minute().second()) }
                                else { Text("未记录批次") }
                            }
                            Text("\(group.jobs.count) 项 · 已完成 \(group.jobs.filter { $0.state == .completed }.count) 项")
                        }
                    }
                }
            }
            if !model.engine.records.isEmpty {
                Section("验证版历史记录") {
                    ForEach(model.engine.records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.name).lineLimit(1)
                            Text(record.stateLabel).font(.caption).foregroundStyle(.secondary)
                            Text("历史内容观察记录，不具有清理资格").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("活动")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Menu {
                Picker("分组方式", selection: $grouping) { Text("按批次").tag("batch"); Text("按备份类型").tag("origin"); Text("不分组").tag("none") }
                Button("暂停全部", systemImage: "pause") { Task { await model.pauseAll() } }
                Button("继续未完成任务", systemImage: "play") { Task { for job in model.visibleJobs where [.paused, .failed, .attention].contains(job.state) { await model.resume(job.id) } } }
                Button("移除当前筛选中的未完成任务", systemImage: "trash", role: .destructive) {
                    removal = Set(filtered.filter(\.unfinished).map(\.id)); confirmRemoval = true
                }.disabled(!filtered.contains(where: \.unfinished))
            } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("activity.menu") }
        }
        .confirmationDialog("移除 \(removal.count) 项未完成任务？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("停止并移除任务", role: .destructive) { let ids = removal; Task { await model.removeUnfinished(ids) } }
            Button("取消", role: .cancel) {}
        } message: { Text("停止这些任务并从活动中移除，释放不再使用的暂存文件。不会删除 iPhone 或谷歌相册中的照片；已经提交的云端内容会保留。自动备份不会重新加入这些项目的同一版本，仍可手动重新备份。") }
    }
    private func activityRow(_ job: BackupJob) -> some View {
        NavigationLink { JobDetailView(id: job.id) } label: { JobRow(job: job) }
            .swipeActions { if job.unfinished {
                Button("移除", role: .destructive) { removal = [job.id]; confirmRemoval = true }
            } }
    }
}

struct JobRow: View {
    let job: BackupJob
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.statusSymbol)
                .font(.title2).foregroundStyle(job.state == .completed ? .green : .blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.sources.first?.name ?? (job.isLive ? "Live Photo" : "照片或视频")).lineLimit(1)
                Text(job.albumsPending ? "媒体已备份 · 等待相簿同步" : job.state.title).font(.caption).foregroundStyle(.secondary)
                if job.state == .transferring { ProgressView(value: job.progress).accessibilityLabel("上传进度") }
            }
            Spacer()
            Text(job.created, style: .date).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var model: HarborModel
    let id: String
    @State private var reprepare = false
    @State private var remove = false
    @Environment(\.dismiss) private var dismiss
    var job: BackupJob? { model.jobs.first { $0.id == id } }
    var body: some View {
        List {
            if let job {
                Section { JobRow(job: job) }
                Section("备份方式") {
                    LabeledContent("画质", value: job.settings.quality.title)
                    if job.isLive { LabeledContent("Live Photo", value: job.settings.live.title) }
                    LabeledContent("编辑版本", value: job.settings.edits.title)
                    LabeledContent("网络", value: job.state == .completed ? (job.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 与蜂窝") : (model.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 与蜂窝"))
                    LabeledContent("来源", value: job.origin?.title ?? "历史任务（未记录）")
                    LabeledContent("资源数", value: String(job.resources.count))
                    LabeledContent("创建时间") { Text(job.created, style: .time) }
                }
                if !job.error.isEmpty { Section("需要处理") {
                    Text(HarborError(job.error).localizedDescription).foregroundStyle(.secondary)
                    if let stage = job.failureStageTitle { LabeledContent([.preparing, .waiting, .confirming, .paired].contains(job.state) ? "当前步骤" : "失败步骤", value: stage) }
                    if let code = job.failureSystemCode { Text(code).font(.caption).foregroundStyle(.secondary) }
                } }
                if job.state == .paired { Section {
                    Label("配对已确认，等待最终云端核验", systemImage: "checkmark.circle.fill").foregroundStyle(.blue)
                    Text("照片与动态视频已指向同一个云端项目。蓝色对勾表示即将完成，尚不计入已备份数量，也不进入清理列表。").font(.footnote).foregroundStyle(.secondary)
                } }
                if let started = job.confirmationStartedAt { Section("确认进度") {
                    LabeledContent("开始核验") { Text(started, style: .time) }
                    if let paired = job.pairedAt { LabeledContent("配对确认") { Text(paired, style: .time) } }
                    LabeledContent("核验次数", value: String(job.confirmationChecks ?? 0))
                    if let seconds = job.lastConfirmationSeconds { LabeledContent("最近一次查询", value: String(format: "%.1f 秒", seconds)) }
                    if let retry = job.retryAt { LabeledContent("下次尝试") { Text(retry, style: .time) } }
                    if let completed = job.completedAt { LabeledContent("完成时间") { Text(completed, style: .time) } }
                    Text("查询耗时包含协议队列等待与网络响应。蓝色配对确认不代表最终核验完成。").font(.footnote).foregroundStyle(.secondary)
                } }
                if let pairs = job.livePairs, !pairs.isEmpty { Section("原始配对测试") {
                    ForEach(pairs) { pair in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(pair.id == "original" ? "原始版本" : "编辑后版本")
                            Text(pair.route == "joint" ? "实际路径：照片与视频联合提交" : pair.route == "reconcile" ? "实际路径：原图确认后关联视频" : pair.confirmed ? "云端已有完整配对，无需再次提交" : "正在查询并选择关联路径")
                            Text(pair.confirmed ? "照片与视频哈希已指向同一云端项目" : pair.submitted ? "关联请求已提交；等待同一项目核验" : "尚未提交配对关联")
                        }.font(.footnote)
                    }
                    Text("已关联不代表配额或官方客户端取回已验收，请核对谷歌相册详情。Live Photo 本地清理保持关闭。").font(.footnote).foregroundStyle(.secondary)
                } }
                if job.isLive && job.settings.live == .motion { Section("动态照片确认") {
                    Text(job.state == .completed ? "文件与云端动态标记均已确认。当前 Live Photo 本地清理仍未开放。" : job.resources.allSatisfy(\.confirmed) && !job.resources.isEmpty ? "封装文件已在云端找到，正在确认动态标记和处理状态；确认阶段不会重新上传文件。" : "将本机照片与配对视频封装为动态文件，再分别确认文件存在与云端动态识别。")
                    Text("任务标题使用本机原名；下方资源名为实际上传文件。Motion Photo 封装会改变文件内容，谷歌相册可能同时显示本机原件与云端封装文件，仅改文件名不能保证合并。")
                }.font(.footnote).foregroundStyle(.secondary) }
                Section("资源") {
                    ForEach(job.resources) { resource in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(resource.name).lineLimit(2)
                            Text("\(resource.role) · \(ByteCountFormatter.string(fromByteCount: resource.size, countStyle: .file)) · \(resource.confirmed ? "云端已确认" : "尚未确认")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if job.state == .completed {
                        Button("按当前设置重新备份") { Task {
                            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil)
                            if let asset = assets.firstObject { await model.enqueue([asset], force: true) }
                            else { model.notice = "无法读取这项照片，请检查相册权限或确认照片仍在本机图库中。" }
                        } }
                    } else if job.state != .cancelled {
                        if job.state == .confirming || job.state == .paired { Button("立即重新确认云端", systemImage: "arrow.clockwise") { Task { await model.resume(id) } }.disabled(model.engine.busy) }
                        if job.state.active || job.state == .queued || job.state == .waiting { Button("暂停", systemImage: "pause") { Task { await model.pause(id) } } }
                        else { Button("继续 / 重试", systemImage: "play") { Task { await model.resume(id) } } }
                        Button("取消任务", role: .destructive) { Task { await model.cancel(id) } }
                    }
                    if [.failed, .attention, .paused].contains(job.state) {
                        Button("重新准备此任务") { reprepare = true }
                    }
                    if job.unfinished { Button("移除未完成任务", role: .destructive) { remove = true } }
                }
            }
        }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重新准备此任务？", isPresented: $reprepare, titleVisibility: .visible) {
            Button("重新读取原件并查重") { Task { await model.reprepare(id) } }
            Button("取消", role: .cancel) {}
        } message: { Text("旧任务保留为已取消，按原任务设置重新读取相册原件并查重。原任务若为强制重新备份，会保留该选择。不删除相册或云端照片。") }
        .confirmationDialog("移除此任务？", isPresented: $remove, titleVisibility: .visible) {
            Button("停止并移除任务", role: .destructive) { Task { await model.removeUnfinished([id]); dismiss() } }
            Button("取消", role: .cancel) {}
        } message: { Text("停止并从活动中移除，不删除本机或云端照片。自动备份不会重新加入该项目的同一版本，仍可手动重新备份。") }
    }
}

struct CleanupView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var confirm = false
    @State private var selected = Set<String>()
    var body: some View {
        List {
            Section {
                Label("确认备份，再释放空间", systemImage: "checkmark.shield").font(.headline)
                Text("检查当前账号的完整备份，并在删除前重新读取本地内容。Live Photo 在完整取回验证通过前会保留。").font(.subheadline).foregroundStyle(.secondary)
                if !model.settings.cloudState || !model.settings.originalAccess {
                    Label("已降低核验强度", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    if !model.settings.cloudState { Text("未检查最新云端状态").font(.caption) }
                    if !model.settings.originalAccess { Text("未检查原件可访问性和大小").font(.caption) }
                }
                Button { Task { await model.verifyCleanup() } } label: { if model.cleanupRunning { ProgressView("正在核验") } else { Text("开始检查") } }.disabled(model.cleanupRunning)
            }
            Section("检查结果") {
                ForEach(model.visibleJobs.filter { model.cleanupResults[$0.id] != nil }) { job in
                    HStack {
                        if model.cleanupReady.contains(job.id) {
                            Button {
                                if selected.contains(job.id) { selected.remove(job.id) } else { selected.insert(job.id) }
                            } label: { Image(systemName: selected.contains(job.id) ? "checkmark.circle.fill" : "circle") }
                                .accessibilityLabel(selected.contains(job.id) ? "取消选择此项目" : "选择此项目").disabled(model.cleanupRunning)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.sources.first?.name ?? "备份资源").lineLimit(1)
                            Text(model.cleanupResults[job.id] ?? "").font(.caption).foregroundStyle(model.cleanupReady.contains(job.id) ? .green : .secondary)
                        }
                    }
                }
            }
            if !model.cleanupReady.isEmpty {
                Section {
                    Button("清理所选 \(selected.count) 项", role: .destructive) { confirm = true }.disabled(model.cleanupRunning || selected.isEmpty)
                } footer: { Text("启用 iCloud 照片时，删除会同步到同一图库的其他设备。照片通常会进入系统“最近删除”。") }
            }
        }.navigationTitle("释放空间").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.cleanupReady) { _, values in selected = Set(values) }
        .alert("确认从 iPhone 相册删除？", isPresented: $confirm) {
            Button("继续核验并请求删除", role: .destructive) { Task { await model.deleteVerified(ids: Array(selected)) } }
            Button("取消", role: .cancel) {}
        } message: { Text("将重新核验 \(selected.count) 项，之后由系统再次请求删除授权。iCloud 照片的删除会同步。谷歌相册中的内容不会被删除。") }
    }
}
