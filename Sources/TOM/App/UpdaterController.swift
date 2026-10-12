import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: ObservableObject {
    /// Weak singleton so AppKit surfaces (status item menu) can trigger
    /// update checks without threading the instance through SwiftUI.
    static private(set) weak var shared: UpdaterController?

    private let controller: SPUStandardUpdaterController
    private let delegate: UpdaterDelegate
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        let u = controller.updater
        self.automaticallyChecksForUpdates = u.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = u.automaticallyDownloadsUpdates
        u.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        Self.shared = self
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// Cache-busts the appcast fetch. Users were stuck on old versions through
/// two stacked caches: the CDN edge holding a stale appcast, and the local
/// NSURLCache heuristically caching whatever the app last received (the
/// feed shipped without Cache-Control headers, so macOS cached it for
/// days). A unique query parameter per check gives every request a fresh
/// cache key end to end — local cache miss AND CDN edge miss — so update
/// discovery always reflects the origin.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let base = Bundle.main.infoDictionary?["SUFeedURL"] as? String else { return nil }
        return "\(base)?t=\(Int(Date().timeIntervalSince1970))"
    }
}
