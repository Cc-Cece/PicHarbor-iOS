import SwiftUI

/// Local removal is performed exclusively by Google Photos.
struct CleanupView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    @State private var unavailable = false
    @State private var opening = false
    @State private var alternatives = false
    var body: some View {
        List {
            Section {
                Label(L10n.text("通过 Google 相册释放空间"), systemImage: "externaldrive.badge.checkmark").font(.headline)
                Text(L10n.text("备份完成后，使用 Google 相册的“释放空间”，由它识别并移除已备份的本机照片和视频。")).foregroundStyle(.secondary)
                Button(L10n.text("前往 Google 相册释放空间")) {
                    opening = true
                    GooglePhotosLauncher.openFreeUpSpace { accepted in
                        opening = false
                        if !accepted { alternatives = true; unavailable = true }
                    }
                }.disabled(opening).accessibilityIdentifier("googlePhotos.open")
            }
            Section {
                Button { alternatives.toggle() } label: {
                    HStack { Text(L10n.text("其他打开方式")); Spacer(); Image(systemName: alternatives ? "chevron.up" : "chevron.down") }
                }.accessibilityIdentifier("googlePhotos.alternatives")
                if alternatives {
                    Text(L10n.text("在主屏幕或 App 资源库中，长按 Google 相册图标，再点“释放空间”。"))
                    Text(L10n.text("也可以打开 Google 相册，点击头像 → Google 相册设定 → 应用程序与装置 → 释放空间。"))
                    Button(L10n.text("打开 Google 相册")) {
                        GooglePhotosLauncher.openApp { if !$0 { unavailable = true } }
                    }.accessibilityIdentifier("googlePhotos.openApp")
                }
            } footer: { Text(L10n.text("请确认 Google 相册当前使用的是备份账号。菜单名称和位置可能因版本或语言有所不同。")) }
            Section {
                Text(L10n.text("请选择释放设备空间，避免误入清理云端存储。移除后可在苹果相册“最近删除”中查看；需要立即腾出空间时，再自行确认是否清空。开启 iCloud 照片时，本机删除也会同步到同一图库的其他设备。")).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(L10n.text("释放空间")).navigationBarTitleDisplayMode(.inline)
        .alert(L10n.text("暂时无法直达释放空间"), isPresented: $unavailable) {
            Button(L10n.text("在 App Store 查看")) { UIApplication.shared.open(GooglePhotosLauncher.appStore) }
            Button(L10n.text("好"), role: .cancel) {}
        } message: { Text(L10n.text("请确认已安装 Google 相册，也可以按“其他打开方式”中的步骤进入。")) }
    }
}
