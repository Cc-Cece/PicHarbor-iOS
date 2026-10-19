import SwiftUI

/// Local removal is performed exclusively by Google Photos.
struct CleanupView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @State private var unavailable = false
    var body: some View {
        List {
            Section {
                Label(L10n.text("通过 Google 相册释放空间"), systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text(L10n.text("备份完成后，使用 Google 相册的“释放空间”，由它识别并移除已备份的本机照片和视频。")).foregroundStyle(.secondary)
                Button(L10n.text("打开 Google 相册")) {
                    GooglePhotosLauncher.open(GooglePhotosLink.launch.url) { if !$0 { unavailable = true } }
                }.accessibilityIdentifier("googlePhotos.open")
            }
            Section(L10n.text("在 Google 相册中操作")) {
                Label(L10n.text("点击首页右上角头像"), systemImage: "1.circle")
                Label(L10n.text("打开“Google 相册设定”"), systemImage: "2.circle")
                Label(L10n.text("进入“应用程序与装置”"), systemImage: "3.circle")
                Label(L10n.text("选择“释放空间”并确认"), systemImage: "4.circle")
            } footer: { Text(L10n.text("以上路径来自关闭备份时的真机测试。菜单名称和位置可能随版本或语言变化，请确认 Google 相册当前使用的是备份账号。")) }
            Section {
                Text(L10n.text("请选择释放设备空间，避免误入清理云端存储。移除后可在苹果相册“最近删除”中查看；需要立即腾出空间时，再自行确认是否清空。开启 iCloud 照片时，本机删除也会同步到同一图库的其他设备。")).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { GooglePhotosLinkTestView() } label: { Label(L10n.text("链接测试（临时）"), systemImage: "link") }.accessibilityIdentifier("googlePhotos.linkTests")
            } footer: { Text(L10n.text("正在测试能否直接打开释放空间页面，目前仍需按上方步骤操作。")) }
        }.navigationTitle(L10n.text("释放空间")).navigationBarTitleDisplayMode(.inline)
        .alert(L10n.text("暂时无法打开 Google 相册"), isPresented: $unavailable) {
            Button(L10n.text("在 App Store 查看")) { UIApplication.shared.open(GooglePhotosLauncher.appStore) }
            Button(L10n.text("好"), role: .cancel) {}
        } message: { Text(L10n.text("请确认已安装 Google 相册，也可以从主屏幕手动打开。")) }
    }
}
