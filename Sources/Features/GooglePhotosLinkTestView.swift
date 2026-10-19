import SwiftUI

/// Temporary manual review surface; remove after routing behavior is verified.
struct GooglePhotosLinkTestView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @StateObject private var tests = GooglePhotosLinkTestStore()
    @State private var backup = "unknown"
    @State private var launch = "unknown"
    @State private var opening: String?
    @State private var clearing = false
    @State private var copied = false
    var body: some View {
        List {
            Section {
                Text(L10n.text("临时测试页面，确认后会移除。除应用启动链接外，以下路径均为猜测，尚无已验证的释放空间直达链接。")).font(.subheadline)
                Text(L10n.text("先测试启动应用，再逐个测试候选。返回 PicHarbor 后记录实际打开的页面。系统接受链接不代表已到达目标页面。")).font(.footnote).foregroundStyle(.secondary)
                Picker(L10n.text("Google 相册备份"), selection: $backup) {
                    Text(L10n.text("未确认")).tag("unknown")
                    Text(L10n.text("已关闭")).tag("off")
                    Text(L10n.text("已开启")).tag("on")
                }
                Picker(L10n.text("测试前应用状态"), selection: $launch) {
                    Text(L10n.text("未确认")).tag("unknown")
                    Text(L10n.text("已退出后台")).tag("cold")
                    Text(L10n.text("仍在后台")).tag("warm")
                }
            } footer: { Text(L10n.text("建议分别测试 Google 相册不在后台、仍在后台，以及备份关闭时的表现。记录每个入口最近一次结果即可。")) }
            ForEach(GooglePhotosLink.candidates) { link in
                Section(link.title) {
                    Text(link.isLaunch ? L10n.text("公开收录的启动链接，待真机确认") : L10n.text("路径猜测，未经验证")).font(.caption).foregroundStyle(link.isLaunch ? Color.secondary : Color.orange)
                    Text(link.address).font(.footnote.monospaced()).textSelection(.enabled)
                    Button(L10n.text("测试此链接")) {
                        let attempt = tests.begin(link, context: "backup=\(backup);launch=\(launch)")
                        opening = link.id
                        GooglePhotosLauncher.open(link.url) { accepted in
                            tests.finish(link, attempt: attempt, accepted: accepted); opening = nil
                        }
                    }.disabled(opening != nil).accessibilityIdentifier("linkTest.open.\(link.id)")
                    if let record = tests.records[link.id] {
                        Text(record.accepted == true ? L10n.text("系统已接受链接，请记录实际页面") : record.accepted == false ? L10n.text("系统未能打开此链接") : L10n.text("尚未收到系统打开结果")).font(.caption).foregroundStyle(.secondary)
                        Text(L10n.date(record.date, time: .short)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Picker(L10n.text("实际打开位置"), selection: Binding(get: { tests.records[link.id]?.destination ?? .unrecorded }, set: { tests.record($0, for: link) })) {
                        ForEach(LinkTestDestination.allCases) { Text($0.title).tag($0) }
                    }.disabled(tests.records[link.id] == nil || opening != nil)
                        .accessibilityIdentifier("linkTest.result.\(link.id)")
                }
            }
            Section {
                Button(L10n.text("复制测试结果")) { UIPasteboard.general.string = tests.report; copied = true }.disabled(tests.records.isEmpty)
                    .accessibilityIdentifier("linkTest.copy")
                ShareLink(item: tests.report) { Label(L10n.text("分享测试结果"), systemImage: "square.and.arrow.up") }.disabled(tests.records.isEmpty)
                Button(L10n.text("清空测试记录"), role: .destructive) { clearing = true }.disabled(tests.records.isEmpty || opening != nil)
            } footer: { Text(L10n.text("结果仅保存在本机，不自动发送。反馈时请补充 Google 相册版本；不需要提供账号或登录凭据。")) }
        }.navigationTitle(L10n.text("链接测试（临时）")).navigationBarTitleDisplayMode(.inline)
        .alert(L10n.text("清空测试记录？"), isPresented: $clearing) {
            Button(L10n.text("清空"), role: .destructive) { tests.clear() }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .alert(L10n.text("已复制测试结果"), isPresented: $copied) { Button(L10n.text("好"), role: .cancel) {} }
    }
}
