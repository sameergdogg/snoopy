import Foundation
import AppKit
import SwiftUI
import SnoopyCore

/// Drives the update check and the download, and owns what the UI shows about it.
///
/// Automatic checking is opt-out rather than silent-by-default-forever: it runs at most once
/// a day, never blocks anything, and a failed check is invisible unless the user asked for
/// it by hand. Nothing is installed without a click — see `UpdateChecker` for why the
/// in-place swap is deliberately not attempted here.
@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case available(UpdateChecker.Release)
        case downloading(Double)          // 0…1
        case downloaded(URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// True when the user started this check, so the result is worth reporting either way.
    @Published private(set) var userInitiated = false

    @AppStorage("dev.snoopy.automaticUpdateChecks") var automaticChecks = true
    /// Release the user asked not to be told about again.
    @AppStorage("dev.snoopy.skippedUpdateVersion") private var skippedVersion = ""

    private static let lastCheckKey = "dev.snoopy.lastUpdateCheck"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private var downloadTask: Task<Void, Never>?

    var availableRelease: UpdateChecker.Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    // MARK: Checking

    /// Called at launch. Quiet: no UI unless there is genuinely something newer.
    func checkInBackgroundIfDue() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > Self.checkInterval else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        guard state != .checking else { return }
        self.userInitiated = userInitiated
        state = .checking
        do {
            let outcome = try await UpdateChecker().check()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
            switch outcome {
            case .available(let release, _):
                // A skipped version stays skipped for a background check, but an explicit
                // "Check for Updates…" always answers honestly.
                if !userInitiated, release.tag == skippedVersion {
                    state = .idle
                } else {
                    state = .available(release)
                }
            case .upToDate(let current):
                state = userInitiated ? .upToDate(current) : .idle
            case .ahead(let current, _):
                state = userInitiated ? .upToDate(current) : .idle
            }
        } catch {
            // A background check that cannot reach GitHub is not the user's problem.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip(_ release: UpdateChecker.Release) {
        skippedVersion = release.tag
        state = .idle
    }

    func dismiss() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    // MARK: Downloading

    func download(_ release: UpdateChecker.Release) {
        guard let url = release.downloadURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        state = .downloading(0)
        downloadTask = Task {
            do {
                let (temp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NSError(domain: "Snoopy.Update", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])
                }
                guard !Task.isCancelled else { return }
                // Into Downloads under the asset's real name, where the user expects it and
                // where it survives this process exiting.
                let name = url.lastPathComponent.isEmpty ? "Snoopy-\(release.tag).dmg" : url.lastPathComponent
                let dest = try Self.uniqueDownloadsURL(named: name)
                try FileManager.default.moveItem(at: temp, to: dest)
                state = .downloaded(dest)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Never silently overwrite something already in Downloads.
    private static func uniqueDownloadsURL(named name: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        var url = dir.appendingPathComponent(name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return url
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens the DMG so the user can drag the app across. Installing over a running copy of
    /// ourselves is exactly the step this deliberately leaves to them.
    func openInstaller(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
