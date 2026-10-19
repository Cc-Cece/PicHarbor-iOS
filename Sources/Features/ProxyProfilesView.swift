import SwiftUI
import UniformTypeIdentifiers

struct ProxyProfilesView: View {
    @ObservedObject private var proxy = ProxyManager.shared
    @EnvironmentObject private var model: HarborModel
    @State private var importer = false
    @State private var working = false
    @State private var status = ""
    private var canChange: Bool { model.activeCount == 0 && !working && !proxy.busy }
    var body: some View {
        Form {
            Section {
                NavigationLink { ProxyProfileEditor() } label: {
                    Label(L10n.text("添加订阅"), systemImage: "plus")
                }.disabled(!canChange)
                Button { importer = true } label: {
                    Label(L10n.text("导入 Clash 配置文件"), systemImage: "doc.badge.plus")
                }.disabled(!canChange)
                Text(L10n.text("从链接或文件导入，任选一种。一次使用一份配置，订阅需手动更新。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if working { ProgressView(L10n.text("正在导入…")) }
            if !status.isEmpty { Section { Text(status).font(.footnote).textSelection(.enabled) } }
            Section(L10n.text("已保存的配置")) {
                ForEach(proxy.library.profiles) { profile in
                    NavigationLink { ProxyProfileEditor(profileID: profile.id) } label: {
                        HStack {
                            Image(systemName: profile.id == proxy.library.activeID ? "checkmark.circle.fill" : "doc.text")
                                .foregroundStyle(profile.id == proxy.library.activeID ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(profile.name).lineLimit(1).truncationMode(.middle)
                                Text(L10n.text("{0} · {1} 个节点", [profile.subscriptionURL == nil ? L10n.text("本地文件") : L10n.text("订阅"), String(profile.nodeCount)]))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(profile.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if proxy.library.profiles.isEmpty { Text(L10n.text("尚未添加配置。")) }
            }
            if model.activeCount > 0 { Text(L10n.text("请先暂停备份，再更新或切换配置。")) }
            Text(L10n.text("仅导入节点，不使用文件中的规则、系统 VPN 或 DNS 设置。最多保存 20 份配置，每份最多 64 个节点。"))
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(L10n.text("配置与订阅"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importer, allowedContentTypes: [.data, .plainText, .json]) { value in
            switch value {
            case .success(let url):
                working = true; status = ""
                Task { @MainActor in
                    defer { working = false }
                    let scope = url.startAccessingSecurityScopedResource()
                    defer { if scope { url.stopAccessingSecurityScopedResource() } }
                    do {
                        guard model.activeCount == 0 else { throw HarborError("PROXY_TASKS_ACTIVE") }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
                        try await proxy.importText(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
                        status = proxy.message
                    } catch { status = error.localizedDescription }
                }
            case .failure: status = L10n.text("未能读取配置文件。")
            }
        }
    }
}

struct ProxyProfileEditor: View {
    var profileID: String? = nil
    @ObservedObject private var proxy = ProxyManager.shared
    @EnvironmentObject private var model: HarborModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var working = false
    @State private var status = ""
    @State private var removal = false
    @State private var loaded = false
    @State private var savedID: String?
    private var currentID: String? { savedID ?? profileID }
    private var profile: ProxyProfile? { proxy.library.profiles.first { $0.id == currentID } }
    private var isSubscription: Bool { profile == nil || profile?.subscriptionURL != nil }
    private var canChange: Bool { model.activeCount == 0 && !working && !proxy.busy }
    var body: some View {
        Form {
            Section {
                TextField(L10n.text("配置名称"), text: $name)
                if isSubscription {
                    TextField(L10n.text("HTTP 或 HTTPS 订阅链接"), text: $address, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(L10n.text("链接仅保存在本机，不加入诊断报告。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }.disabled(working)
            Section {
                if isSubscription {
                    Button(profile == nil ? L10n.text("下载并添加") : L10n.text("更新订阅")) { update() }
                        .disabled(!canChange || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let profile {
                    Button(L10n.text("保存修改")) {
                        do {
                            try proxy.editProfile(profile.id, name: name, address: isSubscription ? address : nil)
                            status = L10n.text("修改已保存，节点内容需更新后生效。")
                        } catch { status = error.localizedDescription }
                    }.disabled(!canChange)
                    if profile.id == proxy.library.activeID { Label(L10n.text("正在使用"), systemImage: "checkmark.circle.fill") }
                    else {
                        Button(L10n.text("使用此配置")) {
                            working = true
                            Task { @MainActor in
                                defer { working = false }
                                do { try await proxy.activateProfile(profile.id); status = proxy.message }
                                catch { status = error.localizedDescription }
                            }
                        }.disabled(!canChange)
                    }
                }
                if working { ProgressView() }
                if !status.isEmpty { Text(status).font(.footnote).textSelection(.enabled) }
            }
            if let profile {
                if let information = profile.information, !information.isEmpty {
                    Section(L10n.text("订阅信息")) {
                        ForEach(information, id: \.self) { Text($0) }
                    }
                }
                if let issues = profile.issues, !issues.isEmpty {
                    Section(L10n.text("暂不可用的节点")) {
                        ForEach(issues) { issue in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(issue.name).lineLimit(1).truncationMode(.middle)
                                Text(issue.kind).font(.caption).foregroundStyle(.secondary)
                                Text(issue.reason).font(.footnote).textSelection(.enabled)
                            }
                        }
                        Text(L10n.text("这些节点已保留，不会用于连接。更新应用或配置后，可重新检查。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button(L10n.text("重新检查兼容性")) {
                        working = true; status = L10n.text("正在检查节点…")
                        Task { @MainActor in
                            defer { working = false }
                            do {
                                guard model.activeCount == 0 else { throw HarborError("PROXY_TASKS_ACTIVE") }
                                let nodes = try JSONSerialization.jsonObject(with: profile.sourceNodes ?? profile.nodes)
                                let data = try JSONSerialization.data(withJSONObject: ["proxies": nodes])
                                try await proxy.importText(String(decoding: data, as: UTF8.self), profileID: profile.id, name: profile.name)
                                status = proxy.message
                            } catch { status = error.localizedDescription }
                        }
                    }.disabled(!canChange)
                }
                Section(L10n.text("更新记录")) {
                    LabeledContent(L10n.text("节点数"), value: String(profile.nodeCount))
                    LabeledContent { Text(profile.updatedAt, format: .dateTime.year().month().day().hour().minute()) } label: { Text(L10n.text("上次成功更新")) }
                    if !profile.lastResult.isEmpty { Text(profile.lastResult).font(.footnote) }
                    if let failure = profile.lastError { Text(failure).font(.footnote).foregroundStyle(.red) }
                }
                Section {
                    Button(L10n.text("移除配置"), role: .destructive) { removal = true }.disabled(!canChange)
                }
            }
        }
        .navigationTitle(L10n.text("配置详情"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let profile { name = profile.name; address = profile.subscriptionURL ?? "" }
        }
        .confirmationDialog(L10n.text("移除此配置？正在使用的配置被移除后，应用内代理将关闭。"), isPresented: $removal, titleVisibility: .visible) {
            Button(L10n.text("移除配置"), role: .destructive) {
                guard let id = currentID else { return }
                working = true
                Task { @MainActor in
                    defer { working = false }
                    do { try await proxy.removeProfile(id); dismiss() }
                    catch { status = error.localizedDescription }
                }
            }
            Button(L10n.text("取消"), role: .cancel) {}
        }
    }
    private func update() {
        working = true; status = L10n.text("正在读取订阅…")
        Task { @MainActor in
            defer { working = false }
            do {
                let url = try ProxySubscription.url(address)
                let route = proxy.preferences.enabled && !proxy.names.isEmpty ? try await proxy.route() : (-1, "")
                let text = try await ProxySubscription.download(url, port: route.0)
                status = L10n.text("订阅已下载，正在导入…")
                guard model.activeCount == 0 else { throw HarborError("PROXY_TASKS_ACTIVE") }
                try await proxy.importText(text, profileID: currentID, name: name.isEmpty ? (url.host ?? "") : name, subscriptionURL: url.absoluteString)
                savedID = currentID ?? proxy.library.activeID
                status = proxy.message
                if let profile { name = profile.name; address = profile.subscriptionURL ?? "" }
            } catch {
                let failure = (error as? HarborError)?.localizedDescription ?? L10n.text("订阅读取失败，请检查网络或改用文件导入。")
                status = failure
                if let id = currentID { proxy.recordProfileFailure(id, message: failure) }
            }
        }
    }
}
