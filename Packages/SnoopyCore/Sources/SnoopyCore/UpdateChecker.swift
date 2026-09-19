import Foundation

/// Checks GitHub Releases for a newer build.
///
/// Snoopy already publishes a signed, notarized DMG to its releases page, so that page is
/// the feed — no appcast to host and no second signing key to manage. What this does *not*
/// do is replace the running app in place: unpacking a DMG over yourself while you are
/// executing from it is the part that goes wrong, and doing it safely is what Sparkle exists
/// for. So the update is downloaded and handed to the user to install, which is one extra
/// click and cannot leave a half-replaced bundle behind.
public struct UpdateChecker: Sendable {

    public struct Release: Sendable, Equatable {
        public let version: AppVersion
        public let tag: String
        public let name: String
        public let notes: String
        public let pageURL: URL
        public let downloadURL: URL?
        public let downloadSize: Int?
        public let isPrerelease: Bool
        public let publishedAt: Date?
    }

    public enum Outcome: Sendable, Equatable {
        case upToDate(current: AppVersion)
        case available(Release, current: AppVersion)
        /// Checked successfully, but this build is newer than anything published — a local
        /// or unreleased build. Saying "up to date" there would be misleading.
        case ahead(current: AppVersion, latest: AppVersion)
    }

    public enum Failure: Error, LocalizedError {
        case network(String)
        case decoding
        case noVersionInBundle
        case rateLimited

        public var errorDescription: String? {
            switch self {
            case .network(let m):     return "Could not reach GitHub: \(m)"
            case .decoding:           return "GitHub returned something unexpected."
            case .noVersionInBundle:  return "This build has no version, so it cannot be compared."
            case .rateLimited:        return "GitHub rate-limited the update check. Try again later."
            }
        }
    }

    public var owner = "sameergdogg"
    public var repo = "snoopy"
    /// Whether prereleases count as updates. Off for final builds, on when this build is
    /// itself a prerelease — someone running an rc wants the next rc.
    public var includePrereleases: Bool

    public init(includePrereleases: Bool? = nil) {
        self.includePrereleases = includePrereleases
            ?? !(AppVersion.current?.prerelease.isEmpty ?? true)
    }

    public func check(current: AppVersion? = AppVersion.current,
                      session: URLSession = .shared) async throws -> Outcome {
        guard let current else { throw Failure.noVersionInBundle }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Snoopy/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        // An update check must never serve a cached "no update" for a day.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.network(error.localizedDescription) }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 403 || http.statusCode == 429 { throw Failure.rateLimited }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure.network("HTTP \(http.statusCode)")
            }
        }

        let releases = try Self.parse(data, includePrereleases: includePrereleases)
        guard let newest = releases.max(by: { $0.version < $1.version }) else {
            return .upToDate(current: current)
        }
        if newest.version > current { return .available(newest, current: current) }
        if newest.version < current { return .ahead(current: current, latest: newest.version) }
        return .upToDate(current: current)
    }

    /// Split out so the JSON shape is testable without a network call.
    public static func parse(_ data: Data, includePrereleases: Bool) throws -> [Release] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.decoding
        }
        let iso = ISO8601DateFormatter()
        return array.compactMap { item -> Release? in
            if (item["draft"] as? Bool) == true { return nil }
            let isPre = (item["prerelease"] as? Bool) ?? false
            if isPre && !includePrereleases { return nil }
            guard let tag = item["tag_name"] as? String,
                  let version = AppVersion(tag),
                  let pageString = item["html_url"] as? String,
                  let page = URL(string: pageString) else { return nil }

            // Prefer the DMG; a .zip is a reasonable fallback if the layout ever changes.
            let assets = (item["assets"] as? [[String: Any]]) ?? []
            let asset = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
                ?? assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }

            return Release(
                version: version,
                tag: tag,
                name: (item["name"] as? String) ?? tag,
                notes: (item["body"] as? String) ?? "",
                pageURL: page,
                downloadURL: (asset?["browser_download_url"] as? String).flatMap(URL.init(string:)),
                downloadSize: asset?["size"] as? Int,
                isPrerelease: isPre,
                publishedAt: (item["published_at"] as? String).flatMap { iso.date(from: $0) })
        }
    }
}
