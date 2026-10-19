import Foundation
import UIKit

@MainActor
enum GooglePhotosLauncher {
    // Listed by Google's production iOS association file and verified on iPhone.
    static let freeUpSpace = URL(string: "https://photos.google.com/link/freeupspace")!
    static let launch = URL(string: "googlephotos://")!
    static let appStore = URL(string: "https://apps.apple.com/app/id962194608")!

    static func openFreeUpSpace(completion: @escaping (Bool) -> Void) {
        // Never fall through to a web page when the app link is unavailable.
        UIApplication.shared.open(freeUpSpace, options: [.universalLinksOnly: true], completionHandler: completion)
    }

    static func openApp(completion: @escaping (Bool) -> Void) {
        guard UIApplication.shared.canOpenURL(launch) else { completion(false); return }
        UIApplication.shared.open(launch, options: [:], completionHandler: completion)
    }
}
