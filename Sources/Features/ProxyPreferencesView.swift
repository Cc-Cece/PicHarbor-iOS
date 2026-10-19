import SwiftUI

struct ProxyPreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @ObservedObject private var proxy = ProxyManager.shared
    @EnvironmentObject private var model: HarborModel
    @State private var working = false
    @State private var result = ""
    private var canChangeCore: Bool { model.activeCount == 0 && !working && !proxy.busy && !proxy.testing }
    private var policy: Binding<ProxyPolicy> {
        Binding(get: { ProxyPolicy.resolve(proxy.preferences) }, set: { value in
            var next = proxy.preferences
            next.selection = value.selection; next.exhaustion = value.exhaustion
            next.primary = value.primary; next.backups = value.backups.filter { $0 != value.primary }
            next.fallback = value.exhaustion == .direct ? .direct : (value.backups.isEmpty ? .wait : .nodes)
            proxy.preferences = next
        })
    }
    private var rankedNames: [String] {
        proxy.names.sorted {
            let af = proxy.health[$0]?.cooling(at: Date()) ?? false, bf = proxy.health[$1]?.cooling(at: Date()) ?? false
            if af != bf { return !af }
            let a = proxy.health[$0]?.milliseconds ?? Int.max, b = proxy.health[$1]?.milliseconds ?? Int.max
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a < b
        }
    }
    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("仅代理 PicHarbor"), isOn: $proxy.preferences.enabled).disabled(!canChangeCore)
                Text(L10n.text("仅用于 PicHarbor 连接 Google，不影响其他应用。")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { ProxyProfilesView() } label: { Label(L10n.text("配置与订阅"), systemImage: "list.bullet.rectangle") }
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
            Section {
                ProxyPolicyFields(policy: policy, names: proxy.names)
                    .disabled(working || proxy.busy || proxy.testing)
                if policy.wrappedValue.selection == .automatic {
                    LabeledContent(L10n.text("当前节点"), value: proxy.currentDirect ? L10n.text("直连") : (proxy.currentNode.isEmpty ? L10n.text("连接时自动选择") : proxy.currentNode))
                    Text(L10n.text("优先保持正常连接，失败后结合延时和近期表现选择其他节点。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text(L10n.text("节点选择与切换")) } footer: {
                Text(L10n.text("任务可单独设置。测速不会中断正在上传的文件；仅在允许时使用直连。"))
            }
            Section {
                if proxy.testing {
                    ProgressView(value: Double(proxy.testedCount), total: Double(max(1, proxy.testTotal)))
                    Text(L10n.text("已测速 {0} / {1} 个节点", [String(proxy.testedCount), String(proxy.testTotal)]))
                    Button(L10n.text("停止测速")) { proxy.stopTesting() }
                } else {
                    Button(L10n.text("测速全部节点")) {
                        result = ""
                        Task {
                            do { try await proxy.testAllNodes(); result = L10n.text("测速完成。") }
                            catch is CancellationError { result = L10n.text("测速已停止。") }
                            catch { result = error.localizedDescription }
                        }
                    }.disabled(working || proxy.busy || proxy.names.isEmpty)
                }
                if working { ProgressView() }
                if !result.isEmpty { Text(result).font(.footnote) }
                ForEach(rankedNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(name).lineLimit(2).truncationMode(.middle)
                            Spacer()
                            if let health = proxy.health[name], let measured = health.measuredAt {
                                VStack(alignment: .trailing) {
                                    Text(health.cooling(at: Date()) ? L10n.text("不可用") : (health.milliseconds.map { L10n.text("{0} 毫秒", [String($0)]) } ?? (health.healthy(at: Date()) ? L10n.text("连接正常") : L10n.text("不可用"))))
                                    Text(measured, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                                }
                            } else { Text(L10n.text("未测速")).foregroundStyle(.secondary) }
                            Button { retest(name) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).accessibilityLabel(L10n.text("重新测速：{0}", [name]))
                                .disabled(working || proxy.testing || proxy.busy)
                        }
                        if proxy.health[name]?.cooling(at: Date()) == true {
                            Text(L10n.text("近期连接失败，稍后重试。")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text(L10n.text("节点测速")) } footer: {
                Text(L10n.text("测试访问 Google 的请求延时，并非上传速度。自动模式会按需补测，结果有效期约 5 分钟。"))
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
    private func retest(_ name: String) {
        working = true
        Task {
            defer { working = false }
            do { try await proxy.retestNode(name) }
            catch { result = error.localizedDescription }
        }
    }
}

private struct ProxyPolicyFields: View {
    @Binding var policy: ProxyPolicy
    let names: [String]
    var body: some View {
        Picker(L10n.text("节点选择"), selection: $policy.selection) {
            ForEach(ProxySelection.allCases) { Text($0.title).tag($0) }
        }
        if policy.selection == .manual {
            Picker(L10n.text("首选节点"), selection: $policy.primary) {
                if !names.contains(policy.primary) { Text(L10n.text("请选择节点")).tag(policy.primary) }
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            ForEach(names.filter { $0 != policy.primary }, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { policy.backups.contains(name) }, set: { selected in
                    policy.backups.removeAll { $0 == name }
                    if selected && policy.backups.count < 8 { policy.backups.append(name) }
                })).disabled(!policy.backups.contains(name) && policy.backups.count >= 8)
            }
            Text(L10n.text("可勾选最多 8 个备用节点，按勾选顺序尝试。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        Picker(L10n.text("所有节点不可用时"), selection: $policy.exhaustion) {
            ForEach(ProxyExhaustion.allCases) { Text($0.title).tag($0) }
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
                    Toggle(L10n.text("跟随全局"), isOn: Binding(get: { job.proxyPolicy == nil && job.proxyFallback == nil }, set: { follow in
                        save(follow ? nil : ProxyPolicy.resolve(proxy.preferences, legacy: job.proxyFallback, override: job.proxyPolicy))
                    }))
                    if job.proxyPolicy != nil || job.proxyFallback != nil {
                        ProxyPolicyFields(policy: Binding(get: {
                            ProxyPolicy.resolve(proxy.preferences, legacy: job.proxyFallback, override: job.proxyPolicy)
                        }, set: { save($0) }), names: proxy.names)
                    } else {
                        LabeledContent(L10n.text("节点选择"), value: ProxyPolicy.resolve(proxy.preferences).selection.title)
                        LabeledContent(L10n.text("所有节点不可用时"), value: ProxyPolicy.resolve(proxy.preferences).exhaustion.title)
                    }
                    if let name = job.proxyLastNode { LabeledContent(L10n.text("最近连接"), value: name.isEmpty ? L10n.text("直连") : name) }
                }.disabled(saving || job.state == .completed)
                Section { Text(L10n.text("只用于此任务，不会改变全局设置。修改后会重新连接，并先检查已备份内容。")) }
            }
        }.navigationTitle(L10n.text("任务连接策略"))
    }
    private func save(_ policy: ProxyPolicy?) {
        saving = true
        Task { await model.setProxyPolicy(id, policy: policy); saving = false }
    }
}
