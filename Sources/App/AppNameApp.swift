import SwiftUI

/// App entry point. Rename this struct to match your app if you like — the
/// `@main` attribute is what matters, not the name.
@main
struct PicHarborApp: App {
  @UIApplicationDelegateAdaptor(HarborAppDelegate.self) private var delegate
  var body: some Scene {
    WindowGroup {
      HarborRootView()
    }
  }
}
