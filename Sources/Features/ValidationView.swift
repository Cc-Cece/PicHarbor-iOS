import SwiftUI

struct ValidationView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @StateObject private var engine = Engine()
    @State private var showLogin = false
    @State private var showPicker = false
    @State private var importedCredential = ""
    @State private var quality = "original"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(L10n.text("PicHarbor · 首轮验证"), systemImage: "photo.on.rectangle.angled")
                        .font(.title3.bold())
                    Text(L10n.text("连接账号，选择一张原始照片，验证上传与云端查重。上传期间请保持应用在前台。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section(L10n.text("A · 运行环境")) {
                    Label(engine.ready ? L10n.text("Python 已启动") : L10n.text("Python 尚未就绪"), systemImage: engine.ready ? "checkmark.circle.fill" : "clock")
                        .foregroundStyle(engine.ready ? .green : .secondary)
                    ForEach(engine.runtime.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: engine.runtime[key] ?? "")
                    }
                    ShareLink(item: engine.diagnostics) { Label(L10n.text("导出诊断报告"), systemImage: "square.and.arrow.up") }
                }
                Section(L10n.text("B · Google 账号")) {
                    if engine.account.isEmpty {
                        Button(L10n.text("登录 Google")) { showLogin = true }.disabled(!engine.ready || engine.busy)
                        DisclosureGroup(L10n.text("高级：导入已有 gpmc 凭据")) {
                            Text(L10n.text("仅用于已有凭据的协议验证。导入不会证明本机网页登录成功；请勿将凭据发送到聊天或上传到仓库。"))
                                .font(.caption).foregroundStyle(.secondary)
                            SecureField(L10n.text("oauth_token 或 gpmc auth_data"), text: $importedCredential)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button(L10n.text("连接已有凭据")) {
                                let value = importedCredential
                                importedCredential = ""
                                Task { await engine.login(value) }
                            }.disabled(importedCredential.isEmpty || !engine.ready || engine.busy)
                        }
                    } else {
                        Text(engine.account).textSelection(.enabled)
                        Button(L10n.text("退出账号"), role: .destructive) { Task { await engine.logout() } }.disabled(engine.busy)
                    }
                }
                Section(L10n.text("单张原始照片")) {
                    Picker(L10n.text("上传模式"), selection: $quality) {
                        Text(L10n.text("计配额原画质")).tag("quota")
                        Text(L10n.text("不计配额原画质")).tag("original")
                        Text(L10n.text("gpmc 节省空间模式")).tag("saver")
                    }.disabled(engine.busy)
                    Text(L10n.text("模式沿用 gpmc 参数，不保证服务端配额结果。暂不支持视频与 Live Photo，也不提供原件删除。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task {
                        if await PhotoSource.authorize() { showPicker = true }
                        else { engine.message = HarborError("PHOTO_PERMISSION").localizedDescription }
                    } } label: { Label(L10n.text("选择一张照片并备份"), systemImage: "icloud.and.arrow.up") }
                        .disabled(engine.account.isEmpty || engine.busy || !engine.ready)
                }
                Section(L10n.text("当前状态")) {
                    Text(L10n.message(engine.message)).textSelection(.enabled)
                    if engine.busy {
                        if let progress = engine.progress { ProgressView(value: progress) }
                        else { ProgressView() }
                        Text(phaseLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L10n.text("最近 100 条记录 · 当前账号")) {
                    if engine.records.isEmpty { Text(L10n.text("连接账号后显示该账号的历史记录。")).foregroundStyle(.secondary) }
                    ForEach(engine.records) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.name).lineLimit(2)
                            Text(record.stateLabel).font(.subheadline).foregroundStyle(record.state == "confirmed" ? .green : .orange)
                            Text(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            if !record.error.isEmpty { Text(HarborError(record.error).localizedDescription).font(.caption).foregroundStyle(.secondary) }
                            Button(L10n.text("重新按内容核验")) { Task { await engine.verify(record) } }.disabled(engine.busy)
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Text(L10n.text("云端哈希确认仅证明查询时存在对应内容，不代表原始质量、完整资产或安全清理资格。重选同一照片可验证查重；重启后重新连接同一账号可验证记录保留。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("PicHarbor")
            .sheet(isPresented: $showLogin) { GoogleLoginView { value in Task { await engine.login(value) } } }
            .sheet(isPresented: $showPicker) {
                OriginalPhotoPicker(selected: { id in Task { await engine.backup(assetID: id, quality: quality) } },
                                    failed: { engine.message = HarborError("PHOTO_PERMISSION").localizedDescription })
            }
            .task { await engine.boot() }
        }
    }

    private var phaseLabel: String {
        ["exporting": L10n.text("正在读取照片原件（iCloud 原件可能需要下载）"), "hashing": L10n.text("正在计算内容哈希"),
         "checking": L10n.text("正在查询云端内容"), "uploading": L10n.text("正在上传"), "committing": L10n.text("正在提交云端记录"),
         "confirming": L10n.text("正在独立查询云端确认")][engine.phase] ?? L10n.text("正在处理")
    }
}
