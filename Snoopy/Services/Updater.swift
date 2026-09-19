import Foundation
import AppKit
import SwiftUI
import Sparkle

/// Wraps Sparkle so SwiftUI can drive it.
///
/// This replaces a hand-rolled checker that could find a new release and download the DMG,
/// but stopped there — it left the user to mount it and drag the app over the running copy.
/// The step it would not take is the one that actually needs care: a process cannot swap its
/// own bundle while executing from it, so the replacement has to be done by a separate
/// helper that waits for the app to exit, moves the new bundle into place and relaunches.
/// That helper, the signature checking that makes it safe to run, and the staging that lets
/// it all happen on quit, are what Sparkle is.
///
/// Configuration lives in Info.plist (see project.yml): the appcast URL, the EdDSA public key
/// updates must be signed with, and automatic check-and-install. `SUAutomaticallyUpdate`
/// means a new version installs in the background and is simply there on the next launch.
@MainActor
final class Updater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own setting so a SwiftUI toggle can read and write it.
    @Published var automaticallyChecks: Bool {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }
    @Published private(set) var canCheck = true

    init() {
        // startingUpdater: true schedules the background check itself; nothing else has to
        // remember to kick it off.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheck)
    }

    /// The user asking explicitly: always answers, including "you're up to date".
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var lastCheckDate: Date? { controller.updater.lastUpdateCheckDate }
}
