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
                Text(L10n.text("仅用于 PicHarbor 连接 Google，不影响其他应用。"))
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
                    ForEach(profile.information ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    if let issues = profile.issues, !issues.isEmpty {
                        Text(L10n.text("另有 {0} 个节点暂不可用，可在配置详情查看。", [String(issues.count)]))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
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
            } header: { Text(L10n.text("连接失败时")) } footer: { Text(L10n.text("任务默认跟随此设置，也可单独调整。仅在你允许时使用直连。")) }
            Section(L10n.text("连接测试")) {
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
                Text(L10n.text("应用进入后台后，代理连接可能暂停；返回应用后可继续备份。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(L10n.text("应用内代理")).navigationBarTitleDisplayMode(.inline)
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
                } footer: { Text(L10n.text("只用于此任务，不会改变全局设置。修改后会重新连接，并先检查已备份内容。")) }
            }
        }.navigationTitle(L10n.text("任务连接策略"))
    }
}
