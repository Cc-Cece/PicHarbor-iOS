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
        if !manager.isAllRequiredSetupCompleted {
            return .blue
        }
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

/// Pure native iOS `Form` (`.insetGrouped`) console with:
/// - Top Notice Banner & Alert feedback
/// - Strict separation of **Required Setup (1/3, 2/3, 3/3)** vs **Optional Actions**
/// - Built-in **Health Check** section
/// - Automatic **Setup Wizard** when mandatory steps are incomplete (with Skip option)
public struct SelfRefreshView: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @State private var showAccountSheet = false
    @State private var showPairingDetailSheet = false
    @State private var showShortcutGuide = false
    @State private var showAboutSheet = false
    @State private var showSetupWizard = false
    @State private var importingFileKind: ImportKind?

    private enum ImportKind: Identifiable {
        case pairingFile
        case localIPA
        var id: Self { self }
    }

    public init() {}

    public var body: some View {
        Form {
            // Prominent Feedback Banner (when an operation succeeds or fails)
            if let notice = manager.activeNotice {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(notice.isError ? .red : .green)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(notice.title)
                                .font(.subheadline.bold())
                            Text(notice.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            manager.activeNotice = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            // Section 1: Current Status & Primary Refresh Action
            Section {
                LabeledContent(manager.localized("描述文件有效期"), value: expirationStatusText)
                LabeledContent(
                    manager.localized("必需配置进度"),
                    value: "\(manager.completedRequiredStepsCount) / 3 \(manager.localized("已完成"))"
                )

                if !manager.isAllRequiredSetupCompleted {
                    Button {
                        showSetupWizard = true
                    } label: {
                        Label(manager.localized("打开首次配置引导向导"), systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("selfRefresh.openWizard")
                }

                if manager.isRefreshing {
                    HStack {
                        ProgressView()
                        Text(manager.statusMessage.isEmpty ? manager.localized("正在处理…") : manager.statusMessage)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        if !manager.isStep1PairingCompleted {
                            importingFileKind = .pairingFile
                        } else if !manager.isStep2AccountCompleted {
                            showAccountSheet = true
                        } else if !manager.isStep3TakeoverCompleted {
                            importingFileKind = .localIPA
                        } else {
                            Task { try? await manager.refreshProfileOnly() }
                        }
                    } label: {
                        Text(primaryButtonTitle)
                            .fontWeight(.medium)
                    }
                    .accessibilityIdentifier("selfRefresh.primaryAction")
                }
            } header: {
                Text(manager.localized("当前状态"))
            } footer: {
                Text(
                    manager.isAllRequiredSetupCompleted
                        ? manager.localized("仅更新描述文件，耗时约 1 秒，应用不会闪退。")
                        : manager.localized("请先完成下方 3 项必需配置，即可解锁 1 秒无感刷新。")
                )
            }

            // Section 2: REQUIRED SETUP (3 Mandatory Items with clear completion badges)
            Section {
                // Required 1: Pairing File
                Button {
                    if manager.isStep1PairingCompleted {
                        showPairingDetailSheet = true
                    } else {
                        importingFileKind = .pairingFile
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: manager.isStep1PairingCompleted ? "checkmark.circle.fill" : "1.circle.fill")
                            .foregroundStyle(manager.isStep1PairingCompleted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.localized("1. 导入设备配对文件"))
                                .foregroundStyle(.primary)
                            if let info = manager.pairingInspection {
                                Text("UDID: \(info.udid)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(manager.isStep1PairingCompleted ? manager.localized("已完成") : manager.localized("未完成 · 点击导入"))
                            .font(.subheadline)
                            .foregroundStyle(manager.isStep1PairingCompleted ? .green : .blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.pairingRow")

                // Required 2: Apple ID Full Login & Session
                Button {
                    showAccountSheet = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: manager.isStep2AccountCompleted ? "checkmark.circle.fill" : "2.circle.fill")
                            .foregroundStyle(manager.isStep2AccountCompleted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.localized("2. 登录 Apple 开发者账号"))
                                .foregroundStyle(.primary)
                            if let session = manager.authSession {
                                Text("\(session.appleID) · Team: \(session.teamID)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(manager.isStep2AccountCompleted ? manager.localized("已认证") : manager.localized("未完成 · 点击登录"))
                            .font(.subheadline)
                            .foregroundStyle(manager.isStep2AccountCompleted ? .green : .blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.accountRow")

                // Required 3: Local Certificate Takeover
                Button {
                    importingFileKind = .localIPA
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: manager.isStep3TakeoverCompleted ? "checkmark.circle.fill" : "3.circle.fill")
                            .foregroundStyle(manager.isStep3TakeoverCompleted ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manager.localized("3. 首次本机签名接管"))
                                .foregroundStyle(.primary)
                            Text(
                                manager.isStep3TakeoverCompleted
                                    ? manager.localized("本机钥匙串证书已接管")
                                    : manager.localized("选择本应用未签名 IPA 完成首次覆盖安装")
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        Spacer()
                        Text(manager.isStep3TakeoverCompleted ? manager.localized("已完成") : manager.localized("待接管"))
                            .font(.subheadline)
                            .foregroundStyle(manager.isStep3TakeoverCompleted ? .green : .blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.takeoverRow")

                // Loopback VPN Status Row
                Button {
                    Task {
                        let connected = await manager.checkTunnelConnection()
                        if !connected {
                            manager.openPreferredVPNApp()
                        } else {
                            manager.postNotice(
                                title: manager.localized("本地隧道已连通"),
                                message: "\(manager.selectedVPN.displayName) (10.7.0.1) 状态正常"
                            )
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: manager.isTunnelConnected ? "network.badge.shield.half.filled" : "exclamationmark.shield")
                            .foregroundStyle(manager.isTunnelConnected ? .green : .blue)
                        Text("\(manager.localized("本地回环隧道")) (\(manager.selectedVPN.displayName))")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(
                            manager.isTunnelConnected
                                ? manager.localized("已连接")
                                : manager.localized("未连接 · 点击开启")
                        )
                        .font(.subheadline)
                        .foregroundStyle(manager.isTunnelConnected ? .green : .blue)
                    }
                }
                .accessibilityIdentifier("selfRefresh.tunnelRow")
            } header: {
                Text(manager.localized("必需操作（完成 3 步后即可无限续签）"))
            }

            // Section 3: Health Status Check (4-Point Diagnostic)
            Section {
                Button {
                    Task { _ = await manager.runHealthCheck() }
                } label: {
                    HStack {
                        Label(manager.localized("运行全面健康状态检查"), systemImage: "stethoscope")
                        Spacer()
                        if manager.isCheckingHealth {
                            ProgressView()
                        } else if let report = manager.healthReport {
                            Text(report.isAllHealthy ? manager.localized("全部正常") : manager.localized("存在提醒"))
                                .font(.caption)
                                .foregroundStyle(report.isAllHealthy ? .green : .orange)
                        }
                    }
                }
                .disabled(manager.isCheckingHealth)
                .accessibilityIdentifier("selfRefresh.healthCheckButton")

                if let report = manager.healthReport {
                    ForEach(report.items) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(
                                systemName: item.status == .healthy
                                    ? "checkmark.circle.fill"
                                    : item.status == .warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(
                                item.status == .healthy ? .green : item.status == .warning ? .orange : .red
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(manager.localized("健康状态检查"))
            } footer: {
                Text(manager.localized("自动实测配对文件、10.7.0.1 本地回环网卡、Anisette V3 节点延迟及 Apple 开发者会话状态。"))
            }

            // Section 4: OPTIONAL ACTIONS (Shortcuts, VPN Switcher, OTA Update)
            Section {
                Picker(manager.localized("首选隧道应用"), selection: $manager.selectedVPN) {
                    ForEach(LoopbackVPNApp.allCases) { vpn in
                        Text(vpn == .localDevVPN ? "\(vpn.displayName) (\(manager.localized("推荐")))" : vpn.displayName)
                            .tag(vpn)
                    }
                }
                .accessibilityIdentifier("selfRefresh.vpnPicker")

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

                if manager.configuration.githubRepository != nil {
                    Button {
                        Task {
                            do {
                                let (_, ipaURL) = try await manager.checkGitHubOTAUpdate()
                                try await manager.downloadAndInstallOTA(from: ipaURL)
                            } catch {
                                manager.postNotice(
                                    title: manager.localized("检查更新失败"),
                                    message: manager.localized(error.localizedDescription),
                                    isError: true
                                )
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
            } header: {
                Text(manager.localized("可选操作（自动化与版本更新）"))
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
            _ = await manager.runHealthCheck()
            if manager.shouldAutoPresentSetupWizard {
                showSetupWizard = true
            }
        }
        .sheet(isPresented: $showSetupWizard) {
            NavigationStack {
                SelfRefreshSetupWizardSheet(
                    onImportPairing: {
                        showSetupWizard = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            importingFileKind = .pairingFile
                        }
                    },
                    onOpenAccountLogin: {
                        showSetupWizard = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showAccountSheet = true
                        }
                    },
                    onImportIPA: {
                        showSetupWizard = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            importingFileKind = .localIPA
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showPairingDetailSheet) {
            NavigationStack {
                SelfRefreshPairingDetailSheet(
                    onReimport: {
                        showPairingDetailSheet = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            importingFileKind = .pairingFile
                        }
                    }
                )
            }
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
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                switch currentKind {
                case .pairingFile:
                    _ = try? manager.importPairingFile(from: url)
                case .localIPA:
                    Task {
                        try? await manager.resignAndInstall(ipaURL: url)
                    }
                case .none:
                    break
                }
            case .failure(let error):
                manager.postNotice(
                    title: manager.localized("文件读取失败"),
                    message: error.localizedDescription,
                    isError: true
                )
            }
        }
    }

    private var primaryButtonTitle: String {
        if !manager.isStep1PairingCompleted {
            return manager.localized("第 1 步：导入设备配对文件")
        }
        if !manager.isStep2AccountCompleted {
            return manager.localized("第 2 步：登录 Apple 开发者账号")
        }
        if !manager.isStep3TakeoverCompleted {
            return manager.localized("第 3 步：选择本应用 IPA 完成首次接管")
        }
        return manager.localized("立即刷新描述文件（1 秒无感续签）")
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
            var types: [UTType] = [.propertyList, .xml, .data]
            if let mobilePairing = UTType(filenameExtension: "mobiledevicepairing") {
                types.insert(mobilePairing, at: 0)
            }
            return types
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
        manager.postNotice(
            title: manager.localized("已复制唤醒链接"),
            message: manager.configuration.refreshWakeupURLString
        )
    }
}

// MARK: - Sheet 1: Interactive Setup Wizard (Auto-Presented When Incomplete, Skippable)

private struct SelfRefreshSetupWizardSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss
    let onImportPairing: () -> Void
    let onOpenAccountLogin: () -> Void
    let onImportIPA: () -> Void

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manager.localized("欢迎使用应用自续签向导"))
                        .font(.headline)
                    Text(manager.localized("只需完成以下 3 项必需设置，本应用即可脱离电脑，在手机上每 7 天直接刷新描述文件（无需重装、不会闪退）。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(manager.localized("第 1 步：设备配对文件")) {
                HStack {
                    Image(systemName: manager.isStep1PairingCompleted ? "checkmark.circle.fill" : "1.circle.fill")
                        .foregroundStyle(manager.isStep1PairingCompleted ? .green : .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.localized("导入 pairingFile.plist / .mobiledevicepairing"))
                            .font(.subheadline.weight(.medium))
                        Text(
                            manager.isStep1PairingCompleted
                                ? "✓ UDID: \(manager.pairedDeviceIdentifier ?? "")"
                                : manager.localized("在电脑上使用 idevice_pair 生成配对文件后传至手机导入。")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Button(manager.isStep1PairingCompleted ? manager.localized("重新选择配对文件") : manager.localized("选择配对文件导入")) {
                    onImportPairing()
                }
            }

            Section(manager.localized("第 2 步：登录 Apple 开发者账号")) {
                HStack {
                    Image(systemName: manager.isStep2AccountCompleted ? "checkmark.circle.fill" : "2.circle.fill")
                        .foregroundStyle(manager.isStep2AccountCompleted ? .green : .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.localized("验证 Apple ID 并保存开发者会话凭证"))
                            .font(.subheadline.weight(.medium))
                        Text(
                            manager.isStep2AccountCompleted
                                ? "✓ \(manager.authSession?.appleID ?? "") (Team: \(manager.authSession?.teamID ?? ""))"
                                : manager.localized("连接 Anisette V3 服务完成登录（支持双重认证验证码），保存长期凭证到本机钥匙串。")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Button(manager.isStep2AccountCompleted ? manager.localized("更换或重新验证账号") : manager.localized("前往登录 Apple ID")) {
                    onOpenAccountLogin()
                }
            }

            Section(manager.localized("第 3 步：开启隧道与首次接管")) {
                HStack {
                    Image(systemName: manager.isStep3TakeoverCompleted ? "checkmark.circle.fill" : "3.circle.fill")
                        .foregroundStyle(manager.isStep3TakeoverCompleted ? .green : .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.localized("开启 LocalDevVPN 并导入 IPA 接管签名"))
                            .font(.subheadline.weight(.medium))
                        Text(
                            manager.isStep3TakeoverCompleted
                                ? manager.localized("✓ 已接管本机证书")
                                : manager.localized("首次安装由电脑签名，需在开启 LocalDevVPN 后选择本应用未签名 IPA 覆盖安装一次。")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Button(manager.localized("开启 LocalDevVPN")) {
                    manager.openPreferredVPNApp()
                }
                Button(manager.localized("选择本应用 IPA 执行首次接管")) {
                    onImportIPA()
                }
                .disabled(!manager.isStep1PairingCompleted || !manager.isStep2AccountCompleted)
            }
        }
        .navigationTitle(manager.localized("首次配置向导"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(manager.localized("跳过引导")) {
                    manager.isSetupGuideSkipped = true
                    dismiss()
                }
                .accessibilityIdentifier("selfRefresh.skipWizard")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(manager.localized("稍后")) {
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Sheet 2: Pairing File Inspection & Backup Export Sheet

private struct SelfRefreshPairingDetailSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss
    let onReimport: () -> Void

    var body: some View {
        Form {
            if let info = manager.pairingInspection {
                Section(manager.localized("配对文件详情")) {
                    LabeledContent("UDID", value: info.udid)
                    LabeledContent("Wi-Fi MAC", value: info.wifiMACAddress)
                    LabeledContent("Host ID", value: info.hostID)
                    LabeledContent("System BUID", value: info.systemBUID)
                    LabeledContent("EscrowBag", value: info.hasEscrowBag ? manager.localized("包含") : manager.localized("无"))
                    LabeledContent("iOS 17+ RPPairing", value: info.hasRPPairingKeys ? manager.localized("包含") : manager.localized("无"))
                }

                Section {
                    if FileManager.default.fileExists(atPath: manager.pairingFileURL.path) {
                        ShareLink(item: manager.pairingFileURL) {
                            Label(manager.localized("导出/备份当前配对文件"), systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(manager.localized("重新导入其他配对文件")) {
                        onReimport()
                    }
                }
            }
        }
        .navigationTitle(manager.localized("设备配对文件"))
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

// MARK: - Sheet 3: Full Apple ID Authentication Sheet (with 2FA & Anisette Presets)

private struct SelfRefreshAccountSheet: View {
    @ObservedObject private var manager = SelfRefreshManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var appleID: String = ""
    @State private var password: String = ""
    @State private var twoFactorCode: String = ""
    @State private var showTwoFactorField: Bool = false
    @State private var anisetteURL: String = ""
    @State private var errorText: String = ""

    var body: some View {
        Form {
            if let session = manager.authSession {
                Section(manager.localized("已认证开发者会话")) {
                    LabeledContent("Apple ID", value: session.appleID)
                    LabeledContent("Team ID", value: session.teamID)
                    LabeledContent("Session Token", value: String(session.sessionToken.prefix(14)) + "…")
                    Button(manager.localized("退出并清除当前凭证"), role: .destructive) {
                        manager.signOutAppleID()
                        password = ""
                    }
                }
            }

            Section {
                TextField("Apple ID (email@icloud.com)", text: $appleID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("selfRefresh.appleIDField")
                SecureField(manager.localized("密码"), text: $password)
                    .accessibilityIdentifier("selfRefresh.passwordField")

                Toggle(manager.localized("需要输入双重认证（2FA）验证码"), isOn: $showTwoFactorField)
                if showTwoFactorField {
                    TextField(manager.localized("6 位数字双重认证验证码"), text: $twoFactorCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .accessibilityIdentifier("selfRefresh.twoFactorField")
                }
            } header: {
                Text(manager.localized("登录 Apple 开发者中心"))
            } footer: {
                Text(manager.localized("点击下方「登录并验证凭证」将连接 Anisette V3 并获取开发者 Team ID 与会话凭证，加密保存在本机钥匙串。"))
            }

            Section {
                Picker(manager.localized("推荐节点"), selection: $anisetteURL) {
                    ForEach(AnisetteServerPreset.defaults) { preset in
                        Text(preset.name).tag(preset.url)
                    }
                }
                TextField("https://ani.sidestore.io", text: $anisetteURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("selfRefresh.anisetteField")

                Button(manager.localized("自动测速选择最快 Anisette 节点")) {
                    Task {
                        anisetteURL = await manager.selectFastestAnisetteServer()
                    }
                }
            } header: {
                Text("Anisette V3")
            }

            if !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        errorText = ""
                        do {
                            _ = try await manager.authenticateAndSaveAccount(
                                appleID: appleID,
                                password: password,
                                twoFactorCode: showTwoFactorField ? twoFactorCode : nil,
                                anisetteURL: anisetteURL
                            )
                            dismiss()
                        } catch {
                            errorText = manager.localized(error.localizedDescription)
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if manager.isAuthenticating {
                            ProgressView()
                            Text(manager.localized("正在连接 Apple 认证服务…"))
                        } else {
                            Text(manager.localized("登录并保存开发者凭证"))
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(manager.isAuthenticating)
                .accessibilityIdentifier("selfRefresh.saveAccount")
            }
        }
        .navigationTitle(manager.localized("Apple ID 登录与认证"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(manager.localized("关闭")) { dismiss() }
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

// MARK: - Sheet 4: Shortcuts Guide & About Component

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
