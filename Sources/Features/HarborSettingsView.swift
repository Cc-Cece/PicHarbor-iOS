import SwiftUI
import Photos

struct HarborSettingsView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var restore = false
    var body: some View {
        List {
            Section {
                NavigationLink { AccountListView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 5) { Text(model.account.isEmpty ? L10n.text("连接 Google 账号") : model.account).font(.headline).lineLimit(1); Text(L10n.text("凭据仅保存在本机钥匙串")).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("settings.account")
            }
            Section(L10n.text("备份")) {
                NavigationLink { BackupPreferencesView() } label: { Label(L10n.text("备份偏好"), systemImage: "icloud.and.arrow.up") }
                NavigationLink { BackupScopeView() } label: { Label(L10n.text("备份范围"), systemImage: "rectangle.stack") }
                NavigationLink { NetworkPreferencesView() } label: { Label(L10n.text("网络与后台"), systemImage: "wifi") }
            }
            Section(L10n.text("设备")) {
                NavigationLink { LanguagePreferencesView() } label: { Label(L10n.text("语言"), systemImage: "globe") }.accessibilityIdentifier("settings.language")
                NavigationLink { PermissionView() } label: { Label(L10n.text("相册访问"), systemImage: "photo.badge.checkmark") }
                NavigationLink { CleanupPolicyView() } label: { Label(L10n.text("空间清理核验"), systemImage: "checkmark.shield") }
                NavigationLink { AppearanceView() } label: { Label(L10n.text("外观"), systemImage: "circle.lefthalf.filled") }
            }
            Section {
                Button(L10n.text("恢复备份与清理默认设置")) { restore = true }
                    .disabled(!model.initialized || model.cleanupRunning || model.switching || model.updatingNetwork || model.storageFailed)
                    .accessibilityIdentifier("settings.restore")
            }
            Section {
                NavigationLink { DiagnosticsView() } label: { Label(L10n.text("诊断"), systemImage: "stethoscope") }
                NavigationLink { AboutView() } label: { Label(L10n.text("关于 PicHarbor"), systemImage: "info.circle") }
            }
        }.navigationTitle(L10n.text("设置"))
        .alert(L10n.text("恢复默认设置？"), isPresented: $restore) {
            Button(L10n.text("恢复默认设置"), role: .destructive) { Task { await model.restorePreferenceDefaults() } }
            Button(L10n.text("取消"), role: .cancel) {}
        } message: { Text(L10n.text("重置当前账号的备份、网络和清理偏好。自动备份将关闭，范围需要重新确认。账号、照片、历史任务、语言及外观会保留，不会重新上传照片。")) }
    }
}

struct BackupPreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form {
            Section {
                Picker(L10n.text("上传画质"), selection: $model.settings.quality) { ForEach(UploadQuality.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden()
            } header: { Text(L10n.text("上传画质")) } footer: { Text(L10n.text("是否占用空间，以 Google 相册显示为准。")) }
            Section {
                Picker(L10n.text("备份方式"), selection: $model.settings.live) { ForEach(LiveStrategy.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden()
            } header: { Text(L10n.text("Live Photo 备份方式")) } footer: {
                Text(model.settings.live == .motion ? L10n.text("将照片和动态视频合成一个文件备份。同机查看时可能出现两张。") : model.settings.live == .applePair ? L10n.text("将原始照片和动态视频一起备份。") : L10n.text("先备份照片，再关联动态视频。"))
                Text(L10n.text("切换方式只影响新任务，已有照片不会自动重新上传。"))
            }
            Section {
                Picker(L10n.text("版本保留"), selection: $model.settings.edits) { ForEach(EditPolicy.allCases) { Text($0.title).tag($0) } }
            } header: { Text(L10n.text("编辑过的照片与视频")) } footer: { Text(L10n.text("同时保留修改前后的内容；内容相同只备份一份。不保留撤销编辑的记录。")) }
            Section {
                Toggle(L10n.text("单向同步相簿"), isOn: $model.settings.syncAlbums)
            } footer: { Text(L10n.text("将本机相簿同步到 Google 相册。从本机相簿移除照片，不会删除云端内容。只对新任务生效。")) }
            Section { NavigationLink(L10n.text("高级备份检查")) { AdvancedBackupChecksView() } }
        }.navigationTitle(L10n.text("备份偏好")).navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }
}

struct AdvancedBackupChecksView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("等待云端完成动态处理"), isOn: Binding(get: { model.settings.requiresStrictConfirmation }, set: { value in
                    model.settings.strictLiveConfirmation = value; Task { await model.saveSettings() }
                })).accessibilityIdentifier("backup.strict")
            } footer: {
                Text(L10n.text("默认关闭。开启后，照片和视频保存成功后还会等待动态处理完成。蓝色对勾表示已保存，仍在等待处理。"))
            }
            Section {
                Button(L10n.text("对等待确认的任务使用此设置")) { Task { await model.applyConfirmationPolicyToPending() } }
                    .disabled(!model.visibleJobs.contains { [.paired, .confirming].contains($0.state) && $0.confirmationOnly })
            } footer: { Text(L10n.text("不会重新上传照片，也不影响已完成的任务。清理本地照片前仍需单独检查。")) }
        }.navigationTitle(L10n.text("高级备份检查")).navigationBarTitleDisplayMode(.inline)
    }
}

struct BackupScopeView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var all = true
    @State private var automatic = true
    var body: some View {
        Form {
            Section {
                Button { selected = []; all = true } label: { HStack { Text(L10n.text("全部可访问照片与视频")); Spacer(); if all { Image(systemName: "checkmark") } } }
                ForEach(model.library.albums) { album in
                    Button {
                        all = false
                        if selected.contains(album.id) { selected.remove(album.id) } else { selected.insert(album.id) }
                    } label: {
                        HStack { Text(album.title).foregroundStyle(.primary); Spacer(); Text(album.count.formatted()).foregroundStyle(.secondary); if selected.contains(album.id) { Image(systemName: "checkmark") } }
                    }
                }
            } header: { Text(L10n.text("备份范围")) } footer: {
                Text(model.library.status == .limited ? L10n.text("有限授权下仅备份你授权的项目，系统可能不提供完整用户相簿。") : L10n.text("照片和视频均包含在范围中。选中相簿按成员合并去重，不重复上传同一个项目。"))
            }
            Section {
                LabeledContent(L10n.text("将备份"), value: L10n.text("{0} 项", [String(describing: scopeCount)]))
                Toggle(L10n.text("确认后开启自动备份"), isOn: $automatic)
                LabeledContent(L10n.text("上传画质"), value: model.settings.quality.title)
                LabeledContent("Live Photo", value: model.settings.live.title)
                LabeledContent(L10n.text("网络"), value: model.settings.wifiOnly ? L10n.text("仅 Wi-Fi") : L10n.text("Wi-Fi 与蜂窝"))
                Button(L10n.text("确认范围与设置")) { Task {
                    model.settings.selectedAlbums = all ? [] : Array(selected).sorted(); model.settings.automatic = automatic
                    model.settings.scopeConfirmed = true
                    if await model.saveSettings() { dismiss() }
                } }.disabled(model.account.isEmpty || (!all && selected.isEmpty))
                if model.account.isEmpty { NavigationLink(L10n.text("请先连接 Google 账号")) { AccountListView() } }
            } footer: { Text(L10n.text("自动备份会识别范围内新增和修改内容。系统后台安排不保证即时，打开应用可继续。")) }
        }.navigationTitle(L10n.text("备份范围")).navigationBarTitleDisplayMode(.inline)
        .onAppear { selected = Set(model.settings.selectedAlbums); all = selected.isEmpty; automatic = model.settings.scopeConfirmed == true ? model.settings.automatic : true }
    }
    private var scopeCount: Int {
        if all { return model.library.assets.count }
        if selected.isEmpty { return 0 }
        var draft = model.settings; draft.selectedAlbums = Array(selected)
        return model.library.scope(draft).count
    }
}

struct NetworkPreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var scope = false
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("仅通过 Wi-Fi 备份"), isOn: $model.settings.wifiOnly)
                Toggle(L10n.text("自动备份"), isOn: Binding(get: { model.settings.automatic }, set: { value in if value { scope = true } else { model.settings.automatic = false } }))
                NavigationLink(L10n.text("检查备份范围")) { BackupScopeView() }
                if model.updatingNetwork { ProgressView(L10n.text("正在为未完成任务应用网络设置…")) }
            } footer: { Text(L10n.text("网络设置立即生效，手动暂停的任务保持暂停。正在上传的文件可能需要重传。关闭自动备份不会取消已有任务。")) }
            Section(L10n.text("后台执行")) {
                Text(L10n.text("后台备份由 iPhone 安排，低电量或网络限制时可能延后。打开应用可继续备份。")).foregroundStyle(.secondary)
                LabeledContent(L10n.text("当前网络"), value: !model.network.connected ? L10n.text("未连接") : model.network.wifi ? "Wi-Fi" : L10n.text("蜂窝网络"))
                LabeledContent(L10n.text("低电量模式"), value: ProcessInfo.processInfo.isLowPowerModeEnabled ? L10n.text("已开启") : L10n.text("未开启"))
                LabeledContent(L10n.text("暂存资源"), value: ByteCountFormatter.string(fromByteCount: model.stagedBytes, countStyle: .file))
            }
        }.navigationTitle(L10n.text("网络与后台")).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scope) { NavigationStack { BackupScopeView() } }
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }
}

struct CleanupPolicyView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var state = true
    @State private var access = true
    @State private var allowLive = false
    @State private var liveConfirmation = false
    @State private var confirmation = false
    @State private var acknowledgment = ""
    var body: some View {
        Form {
            Section {
                Label(state && access && !allowLive ? L10n.text("完整核验") : L10n.text("已放宽清理检查"), systemImage: state && access && !allowLive ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(state && access && !allowLive ? .blue : .orange)
                Text(L10n.text("清理前会核对账号和照片内容，最后由你确认删除。")).font(.subheadline).foregroundStyle(.secondary)
            }
            Section(L10n.text("额外核验")) {
                Toggle(L10n.text("最新云端状态"), isOn: $state)
                Text(L10n.text("确认云端照片正常保存，没有被删除。")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.text("云端原件访问"), isOn: $access)
                Text(L10n.text("确认云端原件可以读取，文件大小正确。")).font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L10n.text("允许清理尚未完整验证的 Live Photo"), isOn: Binding(get: { allowLive }, set: { value in
                    if value { liveConfirmation = true }
                    else { allowLive = false; applyLive() }
                })).accessibilityIdentifier("cleanup.allowLive")
                    .disabled(model.cleanupRunning)
            } footer: {
                Text(L10n.text("默认关闭。开启后，照片和动态视频均已保存即可继续清理检查；取回后可能需要重新配对，部分动态效果可能无法恢复。其他已开启的检查仍会执行。"))
            }
            Section {
                Button(L10n.text("应用核验策略")) {
                    if (!state && model.settings.cloudState) || (!access && model.settings.originalAccess) { acknowledgment = ""; confirmation = true }
                    else { apply() }
                }.disabled(model.cleanupRunning)
                Button(L10n.text("恢复完整核验")) { state = true; access = true; allowLive = false; model.settings.allowUnverifiedLiveCleanup = false; apply() }.disabled(model.cleanupRunning)
            } footer: { Text(L10n.text("修改设置后需重新检查。检查未通过的照片会保留。")) }
        }.navigationTitle(L10n.text("空间清理核验")).navigationBarTitleDisplayMode(.inline)
        .onAppear { state = model.settings.cloudState; access = model.settings.originalAccess; allowLive = model.settings.allowsUnverifiedLiveCleanup }
        .alert(L10n.text("可能影响动态照片的完整取回"), isPresented: $liveConfirmation) {
            Button(L10n.text("了解风险并开启"), role: .destructive) { allowLive = true; applyLive() }
            Button(L10n.text("暂不开启"), role: .cancel) { allowLive = false }
        } message: { Text(L10n.text("照片和视频虽已保存，但尚未确认能完整保存回 iPhone。清理后可能需要手动重新配对，部分动态效果可能无法恢复。")) }
        .alert(L10n.text("降低核验强度"), isPresented: $confirmation) {
            TextField(L10n.text("输入：我已了解风险"), text: $acknowledgment)
            Button(L10n.text("确认降低"), role: .destructive) { if acknowledgment == L10n.text("我已了解风险") { apply() } else { model.notice = L10n.text("确认文字不匹配，策略未改变。") } }
            Button(L10n.text("取消"), role: .cancel) { state = model.settings.cloudState; access = model.settings.originalAccess }
        } message: { Text(L10n.text("将跳过{0}{1}{2}检查。请输入“我已了解风险”。", [String(describing: !state ? L10n.text("最新云端状态") : ""), String(describing: !state && !access ? L10n.text("及") : ""), String(describing: !access ? L10n.text("云端原件访问") : "")])) }
    }
    private func applyLive() { model.settings.allowUnverifiedLiveCleanup = allowLive; Task { await model.saveSettings() } }
    private func apply() { model.settings.cloudState = state; model.settings.originalAccess = access; Task { await model.saveSettings() } }
}

struct AccountListView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @State private var logout = false
    var body: some View {
        List {
            Section(L10n.text("本机账号")) {
                ForEach(model.accounts, id: \.self) { account in
                    Button { Task { await model.switchAccount(account) } } label: { HStack { Label(account, systemImage: "person.crop.circle").foregroundStyle(.primary); Spacer(); if account == model.account { Image(systemName: "checkmark") } } }
                        .disabled(model.engine.busy || model.cleanupRunning)
                }
                NavigationLink { ConnectionView() } label: { Label(L10n.text("添加 Google 账号"), systemImage: "plus") }
                    .accessibilityIdentifier("account.add")
            }
            if model.engine.busy || model.switching { Section { ProgressView(L10n.text("正在连接或切换账号…")) } }
            if model.cleanupRunning { Section { Text(L10n.text("正在核验或清理照片，完成后可连接账号。")).foregroundStyle(.secondary) } }
            if !model.account.isEmpty { Section { Button(L10n.text("退出当前账号"), role: .destructive) { logout = true } } footer: { Text(L10n.text("移除本机凭据并暂停任务；历史记录保留并按账号隔离。")) } }
        }.navigationTitle(L10n.text("账号")).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(L10n.text("退出当前账号？"), isPresented: $logout, titleVisibility: .visible) { Button(L10n.text("退出"), role: .destructive) { Task { await model.logout() } } }
    }
}

struct ConnectionView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    @State private var web = false
    @State private var credential = ""
    @State private var connecting = false
    @State private var pendingCredential: String?
    @State private var loginError = ""
    private var unavailable: Bool { connecting || model.engine.busy || model.switching || model.cleanupRunning || !model.initialized }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 48)).foregroundStyle(.blue)
                    Text(L10n.text("回忆有处安放")).font(.largeTitle.bold())
                    Text(L10n.text("将 iPhone 照片与视频备份到 Google Photos。原生浏览，持续记录进度，由你决定何时清理。")).foregroundStyle(.secondary)
                }.padding(.vertical, 20)
                Button(L10n.text("连接 Google 账号")) { loginError = ""; web = true }
                    .disabled(unavailable || !model.engine.ready).accessibilityIdentifier("connection.google")
            }
            Section {
                SecureField(L10n.text("粘贴登录凭据"), text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { login(credential) } label: { if connecting { ProgressView(L10n.text("正在连接")) } else { Text(L10n.text("导入并连接")) } }.disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unavailable || !model.engine.ready)
            } header: { Text(L10n.text("已有 gpmc 凭据")) } footer: { Text(L10n.text("凭据仅保存在本机钥匙串，不导出到诊断报告。应用内网页登录受 Google 规则影响时，可导入已有凭据。")) }
            Section {
                if connecting || model.engine.busy || model.switching { ProgressView(connecting ? L10n.text("正在连接 Google，请稍候…") : L10n.text("正在准备账号连接…")) }
                else if model.cleanupRunning { Text(L10n.text("请等待照片核验或清理完成后连接账号。")) }
                else if !model.initialized { Text(L10n.text("应用初始化尚未完成。请检查运行环境后重试。")) }
                if !loginError.isEmpty { Text(loginError).foregroundStyle(.red).accessibilityIdentifier("connection.error") }
                Text(L10n.message(model.engine.message)).font(.footnote).foregroundStyle(.secondary)
                if !model.initialized && !model.engine.busy { Button(L10n.text("重新检查运行环境")) { Task { await model.boot() } } }
            }
        }.navigationTitle(L10n.text("欢迎使用 PicHarbor")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("稍后")) { dismiss() }.disabled(connecting) } }
        .interactiveDismissDisabled(connecting)
        .sheet(isPresented: $web, onDismiss: {
            // Finish dismissing WebKit before connecting/dismissing this screen.
            if let value = pendingCredential { pendingCredential = nil; login(value) }
        }) { GoogleLoginView(token: { pendingCredential = $0 }) }
    }
    private func login(_ value: String) {
        connecting = true
        loginError = ""
        Task {
            let success = await model.connect(value)
            connecting = false; credential = ""
            if success { dismiss() } else { loginError = model.connectionError }
        }
    }
}

struct PermissionView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.text("照片访问"), value: model.library.status == .authorized ? L10n.text("完整访问") : model.library.status == .limited ? L10n.text("有限访问") : model.library.status == .denied ? L10n.text("已拒绝，请到系统设置修改") : model.library.status == .restricted ? L10n.text("受系统限制") : L10n.text("尚未请求"))
                if model.library.status == .notDetermined { Button(L10n.text("请求相册访问")) { Task { await model.library.authorize() } } }
                if model.library.status == .limited { Button(L10n.text("管理授权内容")) { model.library.manageLimited() } }
                Button(L10n.text("打开系统设置")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } footer: { Text(L10n.text("有限授权仅显示和备份已授权内容。权限减少不会被视为照片已经删除。原件位于 iCloud 时需联网读取。")) }
        }.navigationTitle(L10n.text("相册访问")).navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form { Picker(L10n.text("外观"), selection: $model.settings.appearance) { Text(L10n.text("跟随系统")).tag("system"); Text(L10n.text("浅色")).tag("light"); Text(L10n.text("深色")).tag("dark") }.pickerStyle(.inline) }
            .navigationTitle(L10n.text("外观")).navigationBarTitleDisplayMode(.inline)
            .onChange(of: model.settings.appearance) { _, _ in Task { await model.saveSettings() } }
    }
}

struct DiagnosticsView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        List {
            Section { ShareLink(item: model.diagnostics) { Label(L10n.text("导出脱敏诊断"), systemImage: "square.and.arrow.up") } } footer: { Text(L10n.text("包含运行环境、任务状态与错误码；不包含凭据、签名地址、照片、文件名或账号。")) }
            Section { Text(model.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.navigationTitle(L10n.text("诊断")).navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 64)).foregroundStyle(.blue)
                    Text("PicHarbor").font(.largeTitle.bold())
                    Text(L10n.text("开发版 {0}", [String(describing: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")])).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            Section { Text(L10n.text("面向 iPhone 的照片与视频备份。取回内容请使用谷歌相册官方客户端。")) }
            Section(L10n.text("开源组件")) {
                Text(L10n.text("gpmc · GPL-3.0\nCPython · Python Software Foundation License\nblackboxprotobuf · MIT\nRequests 及依赖许可证随应用分发。"))
                Link(L10n.text("项目源码与许可证"), destination: URL(string: "https://github.com/Cc-Cece/PicHarbor-iOS")!)
            }
        }.navigationTitle(L10n.text("关于")).navigationBarTitleDisplayMode(.inline)
    }
}
