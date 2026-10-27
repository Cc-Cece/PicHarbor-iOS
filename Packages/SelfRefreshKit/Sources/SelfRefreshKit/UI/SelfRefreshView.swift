import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// Compact native row designed to be embedded directly inside a host app's `List` or `Form` settings screen.
public struct SelfRefreshSection: View {
    @ObservedObject private var manager = SelfRefreshManager.shared

    public init() {}

    public var body: some View {
        NavigationLink {
            SelfRefreshView()
        } label: {
            HStack {
                Label(manager.localized("签名与自动续期"), systemImage: "checkmark.seal")
                Spacer()
                Text(manager.summaryBadgeText)
                    .font(.subheadline)
                    .foregroundStyle(badgeColor)
            }
        }
        .accessibilityIdentifier("settings.selfRefresh")
    }

    private var badgeColor: Color {
        guard let meta = manager.profileMetadata else {
            return .secondary
        }
        if meta.remainingDaysAndHours().isExpired {
            return .red
        }
        if meta.isExpiringSoon() {
            return .orange
        }
        return .secondary
    }
}

/// Pure native iOS `Form` (`.insetGrouped`) console for managing 7-day profile refresh,
/// `LocalDevVPN` loopback check, Shortcuts automation, optional OTA update, and component version info.
public struct SelfRefreshView: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @State private var showAccountSheet = false
    @State private var showShortcutGuide = false
    @State private var showAboutSheet = false
    @State private var importingFileKind: ImportKind?

    private enum ImportKind: Identifiable {
        case pairingFile
        case localIPA
        var id: Self { self }
    }

    public init() {}

    public var body: some View {
        Form {
            // Section 1: Current Status & Primary Refresh Action
            Section {
                LabeledContent(manager.localized("描述文件有效期"), value: expirationStatusText)
                LabeledContent(
                    manager.localized("本机证书状态"),
                    value: manager.isLocalCertificateTakenOver
                        ? manager.localized("已接管")
                        : manager.localized("外部签名（待首次接管）")
                )

                if manager.isRefreshing {
                    HStack {
                        ProgressView()
                        Text(manager.statusMessage.isEmpty ? manager.localized("正在处理…") : manager.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        if manager.isLocalCertificateTakenOver {
                            Task { try? await manager.refreshProfileOnly() }
                        } else {
                            importingFileKind = .localIPA
                        }
                    } label: {
                        Text(
                            manager.isLocalCertificateTakenOver
                                ? manager.localized("立即刷新描述文件")
                                : manager.localized("首次激活：选择本应用 IPA 接管签名")
                        )
                    }
                    .accessibilityIdentifier("selfRefresh.primaryAction")
                }

                if !manager.lastError.isEmpty {
                    Text(manager.lastError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("selfRefresh.error")
                } else if !manager.statusMessage.isEmpty && !manager.isRefreshing {
                    Text(manager.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(manager.localized("当前状态"))
            } footer: {
                Text(
                    manager.isLocalCertificateTakenOver
                        ? manager.localized("仅更新描述文件，耗时约 1 秒，应用不会闪退。")
                        : manager.localized("首次接管将生成本机证书并覆盖安装自身一次，之后即可直接刷新描述文件。")
                )
            }

            // Section 2: Environment Configuration (LocalDevVPN / Pairing / Apple ID)
            Section(manager.localized("环境配置")) {
                Picker(manager.localized("首选隧道应用"), selection: $manager.selectedVPN) {
                    ForEach(LoopbackVPNApp.allCases) { vpn in
                        Text(vpn == .localDevVPN ? "\(vpn.displayName) (\(manager.localized("推荐")))" : vpn.displayName)
                            .tag(vpn)
                    }
                }
                .accessibilityIdentifier("selfRefresh.vpnPicker")

                Button {
                    Task {
                        let connected = await manager.checkTunnelConnection()
                        if !connected {
                            manager.openPreferredVPNApp()
                        }
                    }
                } label: {
                    HStack {
                        Text(manager.localized("本地回环隧道"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Circle()
                            .fill(manager.isTunnelConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(
                            manager.isTunnelConnected
                                ? "\(manager.selectedVPN.displayName) · \(manager.localized("已连接"))"
                                : manager.localized("未连接 · 点击开启")
                        )
                        .font(.subheadline)
                        .foregroundStyle(manager.isTunnelConnected ? Color.secondary : Color.blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.tunnelRow")

                Button {
                    importingFileKind = .pairingFile
                } label: {
                    HStack {
                        Text(manager.localized("设备配对文件"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(
                            manager.pairedDeviceIdentifier != nil
                                ? manager.localized("已导入有效")
                                : manager.localized("点击导入")
                        )
                        .font(.subheadline)
                        .foregroundStyle(manager.pairedDeviceIdentifier != nil ? Color.secondary : Color.blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.pairingRow")

                Button {
                    showAccountSheet = true
                } label: {
                    HStack {
                        Text("Apple ID")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(manager.appleID.isEmpty ? manager.localized("未配置") : manager.appleID)
                            .font(.subheadline)
                            .foregroundStyle(manager.appleID.isEmpty ? Color.blue : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("selfRefresh.accountRow")
            }

            // Section 3: Built-in Shortcuts & Automation
            Section {
                Button {
                    showShortcutGuide = true
                } label: {
                    HStack {
                        Text(manager.localized("配置「自动续签」快捷指令"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(manager.localized("添加与教程"))
                            .font(.subheadline)
                            .foregroundStyle(.blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.shortcutGuide")

                Button {
                    copyWakeupURL()
                } label: {
                    HStack {
                        Text(manager.localized("复制唤醒 URL"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(manager.configuration.refreshWakeupURLString)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("selfRefresh.copyURL")
            } header: {
                Text(manager.localized("快捷指令与自动化"))
            } footer: {
                Text(manager.localized("可在系统「快捷指令」自动化中设置定时连接 LocalDevVPN 并调用此唤醒链接自动完成续签。"))
            }

            // Section 4: Software Update & Full Resign (Optional OTA + Local IPA)
            Section(manager.localized("版本更新与重签")) {
                if manager.configuration.githubRepository != nil {
                    Button {
                        Task {
                            do {
                                let (_, ipaURL) = try await manager.checkGitHubOTAUpdate()
                                try await manager.downloadAndInstallOTA(from: ipaURL)
                            } catch {
                                manager.lastError = manager.localized(error.localizedDescription)
                            }
                        }
                    } label: {
                        HStack {
                            Text(manager.localized("检查云端更新并自签名升级"))
                            Spacer()
                            if let tag = manager.latestOTATag {
                                Text(tag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(manager.isRefreshing)
                    .accessibilityIdentifier("selfRefresh.otaUpdate")
                }

                Button(manager.localized("选择本地 IPA 重签安装")) {
                    importingFileKind = .localIPA
                }
                .disabled(manager.isRefreshing)
                .accessibilityIdentifier("selfRefresh.localIPA")
            }

            // Section 5: Compact About Section (Component Version)
            Section(manager.localized("关于组件")) {
                Button {
                    showAboutSheet = true
                } label: {
                    HStack {
                        Text("SelfRefreshKit")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("v\(SelfRefreshConfiguration.kitVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("selfRefresh.aboutRow")
            }
        }
        .navigationTitle(manager.localized("签名与自动续期"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            manager.reloadEmbeddedProfile()
            _ = await manager.checkTunnelConnection()
        }
        .sheet(isPresented: $showAccountSheet) {
            NavigationStack {
                SelfRefreshAccountSheet()
            }
        }
        .sheet(isPresented: $showShortcutGuide) {
            NavigationStack {
                SelfRefreshShortcutGuideSheet()
            }
        }
        .sheet(isPresented: $showAboutSheet) {
            NavigationStack {
                SelfRefreshAboutSheet()
            }
        }
        .fileImporter(
            isPresented: Binding(
                get: { importingFileKind != nil },
                set: { if !$0 { importingFileKind = nil } }
            ),
            allowedContentTypes: allowedTypes(for: importingFileKind),
            allowsMultipleSelection: false
        ) { result in
            let currentKind = importingFileKind
            importingFileKind = nil
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch currentKind {
            case .pairingFile:
                do {
                    try manager.importPairingFile(from: url)
                } catch {
                    manager.lastError = manager.localized(error.localizedDescription)
                }
            case .localIPA:
                Task {
                    try? await manager.resignAndInstall(ipaURL: url)
                }
            case .none:
                break
            }
        }
    }

    private var expirationStatusText: String {
        guard let meta = manager.profileMetadata else {
            return manager.localized("未检测到内置描述文件")
        }
        let info = meta.remainingDaysAndHours()
        if info.isExpired {
            return manager.localized("已过期")
        }
        return "\(info.days)d \(info.hours)h"
    }

    private func allowedTypes(for kind: ImportKind?) -> [UTType] {
        switch kind {
        case .pairingFile:
            return [.propertyList, .xml, .data]
        case .localIPA:
            if let ipaType = UTType(filenameExtension: "ipa") {
                return [ipaType, .archive, .data]
            }
            return [.archive, .data]
        case .none:
            return [.data]
        }
    }

    private func copyWakeupURL() {
        #if canImport(UIKit)
        UIPasteboard.general.string = manager.configuration.refreshWakeupURLString
        #endif
        manager.statusMessage = manager.localized("已复制唤醒链接。")
    }
}

// MARK: - Sub-Sheets (Account, Shortcuts Guide, About Component)

private struct SelfRefreshAccountSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appleID: String = ""
    @State private var password: String = ""
    @State private var anisetteURL: String = ""
    @State private var errorText: String = ""

    var body: some View {
        Form {
            Section {
                TextField("Apple ID", text: $appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("selfRefresh.appleIDField")
                SecureField(manager.localized("密码"), text: $password)
                    .accessibilityIdentifier("selfRefresh.passwordField")
            } header: {
                Text("Apple ID")
            } footer: {
                Text(manager.localized("凭据仅保存在本机钥匙串，用于向 Apple 申请 7 天个人开发描述文件。"))
            }

            Section("Anisette V3") {
                TextField("https://ani.sidestore.io", text: $anisetteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("selfRefresh.anisetteField")
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(manager.localized("Apple ID 设置"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(manager.localized("取消")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(manager.localized("保存")) {
                    do {
                        try manager.saveCredentials(appleID: appleID, password: password, anisetteURL: anisetteURL)
                        dismiss()
                    } catch {
                        errorText = manager.localized(error.localizedDescription)
                    }
                }
                .accessibilityIdentifier("selfRefresh.saveAccount")
            }
        }
        .onAppear {
            appleID = manager.appleID
            anisetteURL = manager.anisetteURLString
            if let existing = try? SelfRefreshKeychain.loadPassword(for: manager.appleID) {
                password = existing
            }
        }
    }
}

private struct SelfRefreshShortcutGuideSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(manager.localized("自动化配置步骤")) {
                Text(manager.localized("1. 打开系统「快捷指令」应用，切换到「自动化」标签页并创建特定时间（如每天 04:00 立即运行）。"))
                Text(manager.localized("2. 添加动作：开启 LocalDevVPN 连接，等待 2 秒。"))
                Text(manager.localized("3. 添加动作：打开 URL（填入下方唤醒链接）或直接选择本应用的「刷新应用签名描述文件」指令。"))
                Text(manager.localized("4. 添加动作：等待 10 秒后断开 LocalDevVPN。"))
            }

            Section(manager.localized("唤醒链接")) {
                LabeledContent("URL Scheme", value: manager.configuration.refreshWakeupURLString)
                Button(manager.localized("复制唤醒 URL")) {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = manager.configuration.refreshWakeupURLString
                    #endif
                }
                Button(manager.localized("打开系统「快捷指令」应用")) {
                    #if canImport(UIKit)
                    if let url = URL(string: "shortcuts://") {
                        UIApplication.shared.open(url)
                    }
                    #endif
                }
            }
        }
        .navigationTitle(manager.localized("快捷指令与自动化"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(manager.localized("完成")) { dismiss() }
            }
        }
    }
}

private struct SelfRefreshAboutSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section(manager.localized("组件信息")) {
                LabeledContent("SelfRefreshKit", value: "v\(SelfRefreshConfiguration.kitVersion)")
                LabeledContent(manager.localized("通信引擎"), value: SelfRefreshConfiguration.minimuxerEngineVersion)
                LabeledContent(manager.localized("签名引擎"), value: SelfRefreshConfiguration.altSignEngineVersion)
                LabeledContent(manager.localized("首选隧道"), value: manager.selectedVPN.displayName)
                LabeledContent(manager.localized("开源许可证"), value: "MIT License")
            }
            Section {
                Text(manager.localized("轻量级 iOS 应用内置自续签与云端 OTA 通用组件库。默认推荐配合 LocalDevVPN 使用，兼容 StosVPN 与 WireGuard。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(manager.localized("关于 SelfRefreshKit"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(manager.localized("完成")) { dismiss() }
            }
        }
    }
}
