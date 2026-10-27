import SwiftUI
import SelfRefreshKit

/// App entry point. Rename this struct to match your app if you like — the
/// `@main` attribute is what matters, not the name.
@main
struct PicHarborApp: App {
  @UIApplicationDelegateAdaptor(HarborAppDelegate.self) private var delegate

  init() {
    SelfRefreshManager.shared.configure(
      SelfRefreshConfiguration(
        urlScheme: "picharbor",
        preferredVPN: .localDevVPN,
        defaultAnisetteURL: "https://ani.sidestore.io",
        githubRepository: "Cc-Cece/PicHarbor-iOS",
        localizer: { L10n.text($0) == $0 ? SelfRefreshStrings.translate($0, localeIdentifier: L10n.language.rawValue) : L10n.text($0) }
      )
    )
  }

  var body: some Scene {
    WindowGroup {
      HarborRootView()
        .onOpenURL { url in
          _ = SelfRefreshManager.shared.handleOpenURL(url)
        }
    }
  }
}
