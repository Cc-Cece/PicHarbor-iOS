import SwiftUI
import UniformTypeIdentifiers

struct ProxyPreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @ObservedObject private var proxy = ProxyManager.shared
    @EnvironmentObject private var model: HarborModel
    @State private var working = false
    @State private var result = ""
    var canChangeCore: Bool { model.activeCount == 0 && !working && !proxy.busy }
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("仅代理 PicHarbor"), isOn: $proxy.preferences.enabled).disabled(!canChangeCore)
                Text(L10n.text("不创建系统 VPN。其他应用不使用此代理。验证阶段请保持应用在前台。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink {
                    ProxyProfilesView()
                } label: {
                    Label(L10n.text("配置与订阅"), systemImage: "list.bullet.rectangle")
                }
                if let profile = proxy.library.profiles.first(where: { $0.id == proxy.library.activeID }) {
                    Text(L10n.text("正在使用：{0} · {1} 个节点", [profile.name, String(profile.nodeCount)]))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !proxy.names.isEmpty {
                Section {
                    Picker(L10n.text("首选节点"), selection: $proxy.preferences.primary) {
                        ForEach(proxy.names, id: \.self) { Text($0).tag($0) }
                    }.disabled(!canChangeCore)
                    ForEach(proxy.names.filter { $0 != proxy.preferences.primary }, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { proxy.preferences.backups.contains(name) }, set: { selected in
                            proxy.preferences.backups.removeAll { $0 == name }
                            if selected && proxy.preferences.backups.count < 8 { proxy.preferences.backups.append(name) }
                        })).disabled(!canChangeCore)
                    }
                } header: { Text(L10n.text("节点")) } footer: { Text(L10n.text("勾选最多 8 个备用节点。只在允许切换的策略下使用，按勾选顺序尝试。")) }
            }
            Section {
                Picker(L10n.text("代理不可用时"), selection: $proxy.preferences.fallback) {
                    ForEach(ProxyFallback.allCases) { Text($0.title).tag($0) }
                }
            } header: { Text(L10n.text("全局兜底策略")) } footer: { Text(L10n.text("任务默认跟随全局，也可在任务详情单独设置。直连需要明确允许，失败后继续等待，不会标记完成。")) }
            Section(L10n.text("连接验证")) {
                Button(L10n.text("测试当前连接")) {
                    working = true; result = ""
                    Task {
                        defer { working = false }
                        do { let (name, milliseconds) = try await proxy.testPrimaryLatency(); result = L10n.text("首选节点 {0}：{1} 毫秒", [name, String(milliseconds)]) }
                        catch { result = error.localizedDescription }
                    }
                }.disabled(working || proxy.busy)
                if working { ProgressView(L10n.text("正在处理，请稍候…")) }
                if !result.isEmpty { Text(result).font(.footnote) }
                if !proxy.message.isEmpty { Text(proxy.message).font(.footnote) }
            }
            Section {
                Text(L10n.text("请验证：关闭第三方 VPN 后登录并备份；两个任务使用不同兜底；断开节点后重试；锁屏后返回继续。应用被暂停时内置代理可能停止，后台持续上传尚未保证。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "zip", subdirectory: "ProxyNotices") {
                    ShareLink(item: url) { Text(L10n.text("代理组件开源许可")) }
                }
            }
        }.navigationTitle(L10n.text("应用内代理（验证）")).navigationBarTitleDisplayMode(.inline)
        .onChange(of: proxy.preferences.enabled) { _, enabled in
            Task {
                if !enabled { await proxy.stop() }
                else { do { try await proxy.ensureRunning() } catch { result = error.localizedDescription } }
            }
        }
    }
}

struct TaskProxyPreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @ObservedObject private var proxy = ProxyManager.shared
    @EnvironmentObject private var model: HarborModel
    let id: String
    @State private var saving = false
    var job: BackupJob? { model.jobs.first { $0.id == id } }
    var body: some View {
        Form {
            if let job {
                Section {
                    Picker(L10n.text("代理不可用时"), selection: Binding(get: { job.proxyFallback?.rawValue ?? "global" }, set: { value in
                        saving = true
                        Task { await model.setProxyPolicy(id, policy: ProxyFallback(rawValue: value)); saving = false }
                    })) {
                        Text(L10n.text("跟随全局")).tag("global")
                        ForEach(ProxyFallback.allCases) { Text($0.title).tag($0.rawValue) }
                    }.disabled(saving || job.state == .completed)
                    LabeledContent(L10n.text("生效策略"), value: (job.proxyFallback ?? proxy.preferences.fallback).title)
                    if let name = job.proxyLastNode { LabeledContent(L10n.text("最近连接"), value: name.isEmpty ? L10n.text("直连") : name) }
                } footer: { Text(L10n.text("只影响当前任务，随任务保存，不改变全局。修改会暂停当前传输并从文件边界重新连接，已提交内容仍先确认。")) }
            }
        }.navigationTitle(L10n.text("任务连接策略"))
    }
}
