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
            if L10n.message(model.notice) == L10n.text("已加入备份队列。") {
                HStack {
                    Label(L10n.text("已加入备份队列 · {0} 项", [String(describing: model.queueNoticeCount)]), systemImage: "checkmark.circle.fill").font(.subheadline)
                    Spacer()
                    Button(L10n.text("查看活动")) { model.notice = ""; selectedTab = 2 }
                    Button { model.notice = "" } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("关闭备份提示"))
                }.padding().background(.regularMaterial)
            }
        }
        .task(id: model.queueNoticeID) {
            guard L10n.message(model.notice) == L10n.text("已加入备份队列。") else { return }
            let identifier = model.queueNoticeID
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
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
                }.padding(.vertical, 12)
            }
            Section {
                Button { confirm = true } label: { Label(L10n.text("备份当前范围"), systemImage: "arrow.up.circle.fill").font(.headline) }
                    .disabled(model.account.isEmpty || !model.initialized)
                NavigationLink { BackupScopeView() } label: { Label(L10n.text("备份范围"), systemImage: "rectangle.stack") }
                NavigationLink { BackupPreferencesView() } label: { Label(L10n.text("备份偏好"), systemImage: "slider.horizontal.3") }
            }
            Section(L10n.text("当前设置")) {
                LabeledContent(L10n.text("上传画质"), value: model.settings.quality.title)
                LabeledContent("Live Photo", value: model.settings.live.title)
                LabeledContent(L10n.text("自动备份"), value: model.settings.automatic ? L10n.text("已开启") : L10n.text("未开启"))
                LabeledContent(L10n.text("网络"), value: model.settings.wifiOnly ? L10n.text("仅 Wi-Fi") : L10n.text("Wi-Fi 与蜂窝"))
                if !model.network.connected { Label(L10n.text("等待网络连接"), systemImage: "wifi.slash").foregroundStyle(.secondary) }
                else if model.settings.wifiOnly && !model.network.wifi { Label(L10n.text("等待 Wi-Fi"), systemImage: "wifi").foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink { CleanupView() } label: { Label(L10n.text("释放 iPhone 空间"), systemImage: "internaldrive") }
            } footer: { Text(L10n.text("通过 Google 相册释放本机空间。后台备份由系统安排，打开 PicHarbor 可继续推进。")) }
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

struct JobRow: View {
    @ObservedObject private var language = LanguagePreferences.shared
    let job: BackupJob
    var showDate = true
    @State private var filename = false
    var name: String { job.sources.first?.name ?? (job.isLive ? "Live Photo" : L10n.text("照片或视频")) }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.statusSymbol)
                .font(.title2).foregroundStyle(job.state == .completed ? .green : .blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if showDate { Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
                else {
                    Button { filename = true } label: { Text(name).lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading) }
                        .buttonStyle(.plain).accessibilityIdentifier("task.filename").layoutPriority(1)
                        .contextMenu { Button(L10n.text("复制文件名"), systemImage: "doc.on.doc") { UIPasteboard.general.string = name } }
                }
                if showDate { Text(L10n.date(job.created)).font(.caption2).foregroundStyle(.secondary) }
                Text(job.albumsPending ? L10n.text("已备份 · 等待相簿同步") : job.displayStatus).font(.caption).foregroundStyle(.secondary)
                if job.state == .transferring { ProgressView(value: job.progress).accessibilityLabel(L10n.text("上传进度")) }
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
