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
                    Label("已加入备份队列 · \(model.queueNoticeCount) 项", systemImage: "checkmark.circle.fill").font(.subheadline)
                    Spacer()
                    Button("查看活动") { model.notice = ""; selectedTab = 2 }
                    Button { model.notice = "" } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭备份提示")
                }.padding().background(.regularMaterial)
            }
        }
        .task(id: model.queueNoticeID) {
            guard model.notice == "已加入备份队列。" else { return }
            let identifier = model.queueNoticeID
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            if identifier == model.queueNoticeID && model.notice == "已加入备份队列。" { model.notice = "" }
        }
        .task {
            await model.boot()
            #if DEBUG
            if model.installTaskPresentationFixture() { selectedTab = 2; return }
            #endif
            welcome = model.initialized && model.account.isEmpty && selectedTab == 0
        }
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

struct JobRow: View {
    let job: BackupJob
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.statusSymbol)
                .font(.title2).foregroundStyle(job.state == .completed ? .green : .blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(job.sources.first?.name ?? (job.isLive ? "Live Photo" : "照片或视频")).lineLimit(1)
                Text(job.albumsPending ? "已备份 · 等待相簿同步" : job.displayStatus).font(.caption).foregroundStyle(.secondary)
                if job.state == .transferring { ProgressView(value: job.progress).accessibilityLabel("上传进度") }
            }
            Spacer()
            Text(job.created, style: .date).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}
