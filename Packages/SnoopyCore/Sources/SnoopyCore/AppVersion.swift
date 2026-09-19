import Foundation

/// A release version, comparable the way releases actually order.
///
/// String comparison gets this wrong in both directions: "0.10.0" sorts below "0.9.0", and a
/// prerelease sorts above the release it precedes. Both matter for an updater, which would
/// otherwise offer a downgrade or skip a release entirely.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// "rc.1" in 0.2.0-rc.1. Empty for a final release, which ranks *above* any prerelease
    /// of the same numbers (semver rule).
    public let prerelease: String

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? base : "\(base)-\(prerelease)"
    }

    public init(major: Int, minor: Int, patch: Int, prerelease: String = "") {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    /// Parses "v0.2.0", "0.2.0-rc.1", "1.2". Returns nil for anything without a leading number.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }

        // Build metadata ("+abc") carries no precedence and is dropped first — it can follow
        // either the numbers or the prerelease, so handling it inside the prerelease branch
        // alone left "1.2.3+build9" unparseable.
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }
        guard !s.isEmpty else { return nil }

        let core: Substring, pre: String
        if let dash = s.firstIndex(of: "-") {
            core = s[s.startIndex..<dash]
            pre = String(s[s.index(after: dash)...])
        } else {
            core = s[...]
            pre = ""
        }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !numbers.isEmpty, let maj = Int(numbers[0]) else { return nil }
        let min_ = numbers.count > 1 ? Int(numbers[1]) : 0
        let pat = numbers.count > 2 ? Int(numbers[2]) : 0
        guard let min_, let pat else { return nil }
        self.init(major: maj, minor: min_, patch: pat, prerelease: pre)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release outranks its own prereleases: 0.2.0 > 0.2.0-rc.2 > 0.2.0-rc.1.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true):   return false
        case (true, false):  return false   // a is final, b is pre → a > b
        case (false, true):  return true    // a is pre, b is final → a < b
        case (false, false): return comparePrerelease(a.prerelease, b.prerelease)
        }
    }

    /// Dot-separated identifiers, numeric ones compared numerically so rc.10 > rc.9.
    private static func comparePrerelease(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "."), y = b.split(separator: ".")
        for i in 0..<Swift.max(x.count, y.count) {
            guard i < x.count else { return true }    // shorter prerelease sorts first
            guard i < y.count else { return false }
            let (l, r) = (x[i], y[i])
            switch (Int(l), Int(r)) {
            case let (ln?, rn?): if ln != rn { return ln < rn }
            case (_?, nil):      return true          // numeric ranks below alphanumeric
            case (nil, _?):      return false
            default:             if l != r { return l.lexicographicallyPrecedes(r) }
            }
        }
        return false
    }

    /// The version this build reports, preferring the full release channel so a prerelease
    /// build does not think it is the final release of the same number.
    public static var current: AppVersion? {
        let info = Bundle.main.infoDictionary
        if let channel = info?["SnoopyReleaseChannel"] as? String, let v = AppVersion(channel) { return v }
        if let short = info?["CFBundleShortVersionString"] as? String { return AppVersion(short) }
        return nil
    }
}
