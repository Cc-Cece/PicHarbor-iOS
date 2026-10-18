import SwiftUI
import Photos

struct HarborSettingsView: View {
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        List {
            Section {
                NavigationLink { AccountListView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 5) { Text(model.account.isEmpty ? "连接 Google 账号" : model.account).font(.headline).lineLimit(1); Text("凭据仅保存在本机钥匙串").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }.accessibilityIdentifier("settings.account")
            }
            Section("备份") {
                NavigationLink { BackupPreferencesView() } label: { Label("备份偏好", systemImage: "icloud.and.arrow.up") }
                NavigationLink { BackupScopeView() } label: { Label("备份范围", systemImage: "rectangle.stack") }
                NavigationLink { NetworkPreferencesView() } label: { Label("网络与后台", systemImage: "wifi") }
            }
            Section("设备") {
                NavigationLink { PermissionView() } label: { Label("相册访问", systemImage: "photo.badge.checkmark") }
                NavigationLink { CleanupPolicyView() } label: { Label("空间清理核验", systemImage: "checkmark.shield") }
                NavigationLink { AppearanceView() } label: { Label("外观", systemImage: "circle.lefthalf.filled") }
            }
            Section {
                NavigationLink { DiagnosticsView() } label: { Label("诊断", systemImage: "stethoscope") }
                NavigationLink { AboutView() } label: { Label("关于 PicHarbor", systemImage: "info.circle") }
            }
        }.navigationTitle("设置")
    }
}

struct BackupPreferencesView: View {
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form {
            Section {
                Picker("上传画质", selection: $model.settings.quality) { ForEach(UploadQuality.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden()
            } header: { Text("上传画质") } footer: { Text("对应 gpmc 的既有上传模式，实际配额与云端处理结果以服务端为准。") }
            Section {
                Picker("备份方式", selection: $model.settings.live) { ForEach(LiveStrategy.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden()
            } header: { Text("Live Photo 备份方式") } footer: {
                Text(model.settings.live == .motion ? "将对应照片与视频封装为单个 Motion Photo。云端播放与官方客户端取回需完成真机验收。" : model.applePairAvailable ? "保留苹果原始照片、视频与关联信息。" : "开发验证中：云端关联协议尚未验证。选择此方式的 Live Photo 任务会明确等待处理，不会退化为两个独立上传文件。")
            }
            Section {
                Picker("版本保留", selection: $model.settings.edits) { ForEach(EditPolicy.allCases) { Text($0.title).tag($0) } }
            } header: { Text("编辑过的照片与视频") } footer: { Text("默认同时保留原始与编辑后版本，内容不同时在谷歌相册中分别显示；相同则去重。不保存可撤销的苹果编辑历史。") }
            Section {
                Toggle("单向同步相簿", isOn: $model.settings.syncAlbums)
            } footer: { Text("开启后将本地用户相簿添加到应用映射的云端相册；不会因本地移除而删除云端内容。设置只对新任务生效，历史项目可在任务详情按当前设置重新备份。") }
        }.navigationTitle("备份偏好").navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }
}

struct BackupScopeView: View {
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var all = true
    @State private var automatic = true
    var body: some View {
        Form {
            Section {
                Button { selected = []; all = true } label: { HStack { Text("全部可访问照片与视频"); Spacer(); if all { Image(systemName: "checkmark") } } }
                ForEach(model.library.albums) { album in
                    Button {
                        all = false
                        if selected.contains(album.id) { selected.remove(album.id) } else { selected.insert(album.id) }
                    } label: {
                        HStack { Text(album.title).foregroundStyle(.primary); Spacer(); Text(album.count.formatted()).foregroundStyle(.secondary); if selected.contains(album.id) { Image(systemName: "checkmark") } }
                    }
                }
            } header: { Text("备份范围") } footer: {
                Text(model.library.status == .limited ? "有限授权下仅备份你授权的项目，系统可能不提供完整用户相簿。" : "照片和视频均包含在范围中。选中相簿按成员合并去重，不重复上传同一个项目。")
            }
            Section {
                LabeledContent("将备份", value: "\(scopeCount) 项")
                Toggle("确认后开启自动备份", isOn: $automatic)
                LabeledContent("上传画质", value: model.settings.quality.title)
                LabeledContent("Live Photo", value: model.settings.live.title)
                LabeledContent("网络", value: model.settings.wifiOnly ? "仅 Wi-Fi" : "Wi-Fi 与蜂窝")
                Button("确认范围与设置") { Task {
                    model.settings.selectedAlbums = all ? [] : Array(selected).sorted(); model.settings.automatic = automatic
                    model.settings.scopeConfirmed = true
                    if await model.saveSettings() { dismiss() }
                } }.disabled(model.account.isEmpty || (!all && selected.isEmpty))
                if model.account.isEmpty { NavigationLink("请先连接 Google 账号") { AccountListView() } }
            } footer: { Text("自动备份会识别范围内新增和修改内容。系统后台安排不保证即时，打开应用可继续。") }
        }.navigationTitle("备份范围").navigationBarTitleDisplayMode(.inline)
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
    @EnvironmentObject private var model: HarborModel
    @State private var scope = false
    var body: some View {
        Form {
            Section {
                Toggle("仅通过 Wi-Fi 备份", isOn: $model.settings.wifiOnly)
                Toggle("自动备份", isOn: Binding(get: { model.settings.automatic }, set: { value in if value { scope = true } else { model.settings.automatic = false } }))
                NavigationLink("检查备份范围") { BackupScopeView() }
            } footer: { Text("网络设置对新建任务生效；已创建任务保留原设置。关闭自动备份不会取消手动任务，可在活动中暂停任务。") }
            Section("后台执行") {
                Text("大文件由系统后台传输。图库扫描、封装与提交由系统尽力安排，前台打开时可靠继续。系统强制结束、低电量或网络限制可能延后任务。").foregroundStyle(.secondary)
                LabeledContent("当前网络", value: !model.network.connected ? "未连接" : model.network.wifi ? "Wi-Fi" : "蜂窝网络")
                LabeledContent("低电量模式", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "已开启" : "未开启")
                LabeledContent("暂存资源", value: ByteCountFormatter.string(fromByteCount: model.stagedBytes, countStyle: .file))
            }
        }.navigationTitle("网络与后台").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scope) { NavigationStack { BackupScopeView() } }
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }
}

struct CleanupPolicyView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var state = true
    @State private var access = true
    @State private var confirmation = false
    @State private var acknowledgment = ""
    var body: some View {
        Form {
            Section {
                Label(state && access ? "完整核验" : "已降低核验强度", systemImage: state && access ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(state && access ? .blue : .orange)
                Text("账号匹配、本地内容读取与哈希、服务端内容匹配、删除前变化检查，以及用户和系统确认始终启用。").font(.subheadline).foregroundStyle(.secondary)
            }
            Section("额外核验") {
                Toggle("最新云端状态", isOn: $state)
                Text("检查回收站、处理状态、原画质标记与大小。").font(.caption).foregroundStyle(.secondary)
                Toggle("云端原件访问", isOn: $access)
                Text("获取原件地址并检查可访问性与大小，不完整下载。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("应用核验策略") {
                    if (!state && model.settings.cloudState) || (!access && model.settings.originalAccess) { acknowledgment = ""; confirmation = true }
                    else { apply() }
                }.disabled(model.cleanupRunning)
                Button("恢复完整核验") { state = true; access = true; apply() }.disabled(model.cleanupRunning)
            } footer: { Text("改变策略会使已有清理资格失效。已开启的检查失败时不会被自动跳过。") }
        }.navigationTitle("清理核验").navigationBarTitleDisplayMode(.inline)
        .onAppear { state = model.settings.cloudState; access = model.settings.originalAccess }
        .alert("降低核验强度", isPresented: $confirmation) {
            TextField("输入：我已了解风险", text: $acknowledgment)
            Button("确认降低", role: .destructive) { if acknowledgment == "我已了解风险" { apply() } else { model.notice = "确认文字不匹配，策略未改变。" } }
            Button("取消", role: .cancel) { state = model.settings.cloudState; access = model.settings.originalAccess }
        } message: { Text("将跳过\(!state ? "最新云端状态" : "")\(!state && !access ? "及" : "")\(!access ? "云端原件访问" : "")检查。请输入“我已了解风险”。") }
    }
    private func apply() { model.settings.cloudState = state; model.settings.originalAccess = access; Task { await model.saveSettings() } }
}

struct AccountListView: View {
    @EnvironmentObject private var model: HarborModel
    @State private var logout = false
    var body: some View {
        List {
            Section("本机账号") {
                ForEach(model.accounts, id: \.self) { account in
                    Button { Task { await model.switchAccount(account) } } label: { HStack { Label(account, systemImage: "person.crop.circle").foregroundStyle(.primary); Spacer(); if account == model.account { Image(systemName: "checkmark") } } }
                        .disabled(model.engine.busy || model.cleanupRunning)
                }
                NavigationLink { ConnectionView() } label: { Label("添加 Google 账号", systemImage: "plus") }
                    .accessibilityIdentifier("account.add")
            }
            if model.engine.busy || model.switching { Section { ProgressView("正在连接或切换账号…") } }
            if model.cleanupRunning { Section { Text("正在核验或清理照片，完成后可连接账号。").foregroundStyle(.secondary) } }
            if !model.account.isEmpty { Section { Button("退出当前账号", role: .destructive) { logout = true } } footer: { Text("移除本机凭据并暂停任务；历史记录保留并按账号隔离。") } }
        }.navigationTitle("账号").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出当前账号？", isPresented: $logout, titleVisibility: .visible) { Button("退出", role: .destructive) { Task { await model.logout() } } }
    }
}

struct ConnectionView: View {
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
                    Text("回忆有处安放").font(.largeTitle.bold())
                    Text("将 iPhone 照片与视频备份到 Google Photos。原生浏览，持续记录进度，由你决定何时清理。").foregroundStyle(.secondary)
                }.padding(.vertical, 20)
                Button("连接 Google 账号") { loginError = ""; web = true }
                    .disabled(unavailable || !model.engine.ready).accessibilityIdentifier("connection.google")
            }
            Section {
                SecureField("粘贴登录凭据", text: $credential).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { login(credential) } label: { if connecting { ProgressView("正在连接") } else { Text("导入并连接") } }.disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || unavailable || !model.engine.ready)
            } header: { Text("已有 gpmc 凭据") } footer: { Text("凭据仅保存在本机钥匙串，不导出到诊断报告。应用内网页登录受 Google 规则影响时，可导入已有凭据。") }
            Section {
                if connecting || model.engine.busy || model.switching { ProgressView(connecting ? "正在连接 Google，请稍候…" : "正在准备账号连接…") }
                else if model.cleanupRunning { Text("请等待照片核验或清理完成后连接账号。") }
                else if !model.initialized { Text("应用初始化尚未完成。请检查运行环境后重试。") }
                if !loginError.isEmpty { Text(loginError).foregroundStyle(.red).accessibilityIdentifier("connection.error") }
                Text(model.engine.message).font(.footnote).foregroundStyle(.secondary)
                if !model.initialized && !model.engine.busy { Button("重新检查运行环境") { Task { await model.boot() } } }
            }
        }.navigationTitle("欢迎使用 PicHarbor").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("稍后") { dismiss() }.disabled(connecting) } }
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
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form {
            Section {
                LabeledContent("照片访问", value: model.library.status == .authorized ? "完整访问" : model.library.status == .limited ? "有限访问" : model.library.status == .denied ? "已拒绝，请到系统设置修改" : model.library.status == .restricted ? "受系统限制" : "尚未请求")
                if model.library.status == .notDetermined { Button("请求相册访问") { Task { await model.library.authorize() } } }
                if model.library.status == .limited { Button("管理授权内容") { model.library.manageLimited() } }
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } footer: { Text("有限授权仅显示和备份已授权内容。权限减少不会被视为照片已经删除。原件位于 iCloud 时需联网读取。") }
        }.navigationTitle("相册访问").navigationBarTitleDisplayMode(.inline)
    }
}

struct AppearanceView: View {
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        Form { Picker("外观", selection: $model.settings.appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.inline) }
            .navigationTitle("外观").navigationBarTitleDisplayMode(.inline)
            .onChange(of: model.settings.appearance) { _, _ in Task { await model.saveSettings() } }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var model: HarborModel
    var body: some View {
        List {
            Section { ShareLink(item: model.diagnostics) { Label("导出脱敏诊断", systemImage: "square.and.arrow.up") } } footer: { Text("包含运行环境、任务状态与错误码；不包含凭据、签名地址、照片、文件名或账号。") }
            Section { Text(model.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
        }.navigationTitle("诊断").navigationBarTitleDisplayMode(.inline)
    }
}

private struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 64)).foregroundStyle(.blue)
                    Text("PicHarbor").font(.largeTitle.bold())
                    Text("开发版 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            }
            Section { Text("面向 iPhone 的照片与视频备份。取回内容请使用谷歌相册官方客户端。") }
            Section("开源组件") {
                Text("gpmc · GPL-3.0\nCPython · Python Software Foundation License\nblackboxprotobuf · MIT\nRequests 及依赖许可证随应用分发。")
                Link("项目源码与许可证", destination: URL(string: "https://github.com/Cc-Cece/PicHarbor-iOS")!)
            }
        }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    }
}
