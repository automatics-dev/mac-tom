import Combine
import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let u = controller.updater
        self.automaticallyChecksForUpdates = u.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = u.automaticallyDownloadsUpdates
        u.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
