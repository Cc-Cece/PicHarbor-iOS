import SwiftUI

/// App entry point. Rename this struct to match your app if you like — the
/// `@main` attribute is what matters, not the name.
@main
struct PicHarborApp: App {
  var body: some Scene {
    WindowGroup {
      ValidationView()
    }
  }
}
