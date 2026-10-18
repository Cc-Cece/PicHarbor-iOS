import SwiftUI
import Photos

struct HarborRootView: View {
    @StateObject private var model = HarborModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var welcome = false
    var body: some View {
        TabView {
            NavigationStack { LibraryView() }.tabItem { Label("照片", systemImage: "photo.on.rectangle") }
            NavigationStack { BackupDashboard() }.tabItem { Label("备份", systemImage: "icloud.and.arrow.up") }
            NavigationStack { ActivityView() }.tabItem { Label("活动", systemImage: "clock.arrow.circlepath") }
            NavigationStack { HarborSettingsView() }.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .environmentObject(model)
        .tint(.blue)
        .preferredColorScheme(model.settings.appearance == "dark" ? .dark : model.settings.appearance == "light" ? .light : nil)
        .task { await model.boot(); welcome = model.initialized && model.account.isEmpty }
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
    var filtered: [BackupJob] { model.visibleJobs.filter { filter == "all" || (filter == "done" ? $0.state == .completed : $0.state != .completed) } }
    var body: some View {
        List {
            Section {
                Picker("任务", selection: $filter) { Text("全部").tag("all"); Text("进行中").tag("active"); Text("已完成").tag("done") }.pickerStyle(.segmented)
            }
            if filtered.isEmpty { ContentUnavailableView("暂无备份活动", systemImage: "clock", description: Text("备份任务和处理结果会显示在这里。")) }
            ForEach(filtered) { job in
                NavigationLink { JobDetailView(id: job.id) } label: { JobRow(job: job) }
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
                Button("暂停全部", systemImage: "pause") { Task { await model.pauseAll() } }
                Button("继续未完成任务", systemImage: "play") { Task { for job in model.visibleJobs where [.paused, .failed, .attention].contains(job.state) { await model.resume(job.id) } } }
            } label: { Image(systemName: "ellipsis.circle") } }
        }
    }
}

struct JobRow: View {
    let job: BackupJob
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.state == .completed ? "checkmark.circle.fill" : job.state == .failed || job.state == .attention ? "exclamationmark.circle" : "icloud.and.arrow.up")
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
    var job: BackupJob? { model.jobs.first { $0.id == id } }
    var body: some View {
        List {
            if let job {
                Section { JobRow(job: job) }
                Section("备份方式") {
                    LabeledContent("画质", value: job.settings.quality.title)
                    if job.isLive { LabeledContent("Live Photo", value: job.settings.live.title) }
                    LabeledContent("编辑版本", value: job.settings.edits.title)
                    LabeledContent("资源数", value: String(job.resources.count))
                    LabeledContent("创建时间") { Text(job.created, style: .time) }
                }
                if !job.error.isEmpty { Section("需要处理") { Text(HarborError(job.error).localizedDescription).foregroundStyle(.secondary) } }
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
                        } }
                    } else if job.state != .cancelled {
                        if job.state.active || job.state == .queued || job.state == .waiting { Button("暂停", systemImage: "pause") { Task { await model.pause(id) } } }
                        else { Button("继续 / 重试", systemImage: "play") { Task { await model.resume(id) } } }
                        Button("取消任务", role: .destructive) { Task { await model.cancel(id) } }
                    }
                }
            }
        }.navigationTitle("任务详情").navigationBarTitleDisplayMode(.inline)
    }
}

struct CleanupView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var confirm = false
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
                    VStack(alignment: .leading, spacing: 5) {
                        Text(job.sources.first?.name ?? "备份资源").lineLimit(1)
                        Text(model.cleanupResults[job.id] ?? "").font(.caption).foregroundStyle(model.cleanupReady.contains(job.id) ? .green : .secondary)
                    }
                }
            }
            if !model.cleanupReady.isEmpty {
                Section {
                    Button("清理 \(model.cleanupReady.count) 项", role: .destructive) { confirm = true }.disabled(model.cleanupRunning)
                } footer: { Text("启用 iCloud 照片时，删除会同步到同一图库的其他设备。照片通常会进入系统“最近删除”。") }
            }
        }.navigationTitle("释放空间").navigationBarTitleDisplayMode(.inline)
        .alert("确认从 iPhone 相册删除？", isPresented: $confirm) {
            Button("继续核验并请求删除", role: .destructive) { Task { await model.deleteVerified() } }
            Button("取消", role: .cancel) {}
        } message: { Text("将重新核验 \(model.cleanupReady.count) 项，之后由系统再次请求删除授权。iCloud 照片的删除会同步。谷歌相册中的内容不会被删除。") }
    }
}
