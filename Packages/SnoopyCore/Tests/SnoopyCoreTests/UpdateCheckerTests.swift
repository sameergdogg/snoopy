import XCTest
@testable import SnoopyCore

final class AppVersionTests: XCTestCase {

    func testParsesTheFormsReleasesActuallyUse() {
        XCTAssertEqual(AppVersion("0.2.0")?.description, "0.2.0")
        XCTAssertEqual(AppVersion("v0.2.0")?.description, "0.2.0")
        XCTAssertEqual(AppVersion("0.2.0-rc.1")?.description, "0.2.0-rc.1")
        XCTAssertEqual(AppVersion("1.2")?.description, "1.2.0")
        XCTAssertEqual(AppVersion("3")?.description, "3.0.0")
        XCTAssertEqual(AppVersion("1.2.3+build9")?.description, "1.2.3", "build metadata is not precedence")
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion(""))
    }

    /// The bug string comparison would cause: an updater that never offers 0.10.0 to someone
    /// on 0.9.0, because "0.10.0" < "0.9.0" as text.
    func testNumericOrderingNotLexicographic() {
        XCTAssertLessThan(AppVersion("0.9.0")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("1.10.0")!)
        XCTAssertLessThan(AppVersion("0.2.9")!, AppVersion("0.3.0")!)
        XCTAssertGreaterThan(AppVersion("2.0.0")!, AppVersion("1.99.99")!)
    }

    /// The other direction: an updater that offers a prerelease as an "upgrade" from the
    /// final release it preceded.
    func testReleaseOutranksItsOwnPrereleases() {
        XCTAssertGreaterThan(AppVersion("0.2.0")!, AppVersion("0.2.0-rc.1")!)
        XCTAssertGreaterThan(AppVersion("0.2.0")!, AppVersion("0.2.0-rc.9")!)
        XCTAssertLessThan(AppVersion("0.2.0-rc.1")!, AppVersion("0.2.0-rc.2")!)
        XCTAssertLessThan(AppVersion("0.2.0-rc.9")!, AppVersion("0.2.0-rc.10")!,
                          "rc.10 follows rc.9; text ordering would reverse them")
        XCTAssertLessThan(AppVersion("0.2.0")!, AppVersion("0.2.1-rc.1")!)
    }

    func testEquality() {
        XCTAssertEqual(AppVersion("0.2.0"), AppVersion("v0.2.0"))
        XCTAssertFalse(AppVersion("0.2.0")! < AppVersion("0.2.0")!)
    }

    func testSortingAMixedReleaseList() {
        let sorted = ["0.10.0", "0.2.0", "0.9.0", "0.10.0-rc.1", "1.0.0"]
            .compactMap(AppVersion.init).sorted().map(\.description)
        XCTAssertEqual(sorted, ["0.2.0", "0.9.0", "0.10.0-rc.1", "0.10.0", "1.0.0"])
    }
}

final class UpdateCheckerParsingTests: XCTestCase {

    private func feed(_ releases: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: releases)
    }

    private func release(tag: String, prerelease: Bool = false, draft: Bool = false,
                         assets: [[String: Any]] = [["name": "Snoopy-x.dmg",
                                                     "browser_download_url": "https://example.com/Snoopy.dmg",
                                                     "size": 2_272_914]]) -> [String: Any] {
        ["tag_name": tag, "name": "Snoopy \(tag)", "body": "notes for \(tag)",
         "html_url": "https://github.com/o/r/releases/tag/\(tag)",
         "prerelease": prerelease, "draft": draft, "assets": assets,
         "published_at": "2026-09-14T14:48:34Z"]
    }

    func testPicksTheDMGAsset() throws {
        let out = try UpdateChecker.parse(feed([release(tag: "v0.2.0")]), includePrereleases: false)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].version, AppVersion("0.2.0"))
        XCTAssertEqual(out[0].downloadURL?.lastPathComponent, "Snoopy.dmg")
        XCTAssertEqual(out[0].downloadSize, 2_272_914)
        XCTAssertNotNil(out[0].publishedAt)
    }

    func testIgnoresChecksumAssetsWhenChoosingTheDownload() throws {
        let assets: [[String: Any]] = [
            ["name": "Snoopy-0.2.0.dmg.sha256", "browser_download_url": "https://e/x.sha256", "size": 121],
            ["name": "Snoopy-0.2.0.dmg", "browser_download_url": "https://e/Snoopy-0.2.0.dmg", "size": 999],
        ]
        let out = try UpdateChecker.parse(feed([release(tag: "v0.2.0", assets: assets)]),
                                          includePrereleases: false)
        XCTAssertEqual(out[0].downloadURL?.lastPathComponent, "Snoopy-0.2.0.dmg",
                       "the .sha256 sits before the .dmg and must not be picked")
    }

    func testDraftsAreNeverOffered() throws {
        let out = try UpdateChecker.parse(feed([release(tag: "v0.3.0", draft: true),
                                                release(tag: "v0.2.0")]),
                                          includePrereleases: true)
        XCTAssertEqual(out.map(\.tag), ["v0.2.0"])
    }

    func testPrereleasesAreOptIn() throws {
        let data = feed([release(tag: "v0.3.0-rc.1", prerelease: true), release(tag: "v0.2.0")])
        XCTAssertEqual(try UpdateChecker.parse(data, includePrereleases: false).map(\.tag), ["v0.2.0"])
        XCTAssertEqual(try UpdateChecker.parse(data, includePrereleases: true).count, 2)
    }

    func testReleasesWithoutAUsableTagAreSkipped() throws {
        let out = try UpdateChecker.parse(feed([release(tag: "nightly"), release(tag: "v0.2.0")]),
                                          includePrereleases: false)
        XCTAssertEqual(out.map(\.tag), ["v0.2.0"])
    }

    func testReleaseWithNoAssetStillOffersThePage() throws {
        let out = try UpdateChecker.parse(feed([release(tag: "v0.2.0", assets: [])]),
                                          includePrereleases: false)
        XCTAssertNil(out[0].downloadURL)
        XCTAssertEqual(out[0].pageURL.absoluteString, "https://github.com/o/r/releases/tag/v0.2.0")
    }

    func testGarbageResponseIsAnError() {
        XCTAssertThrowsError(try UpdateChecker.parse(Data("not json".utf8), includePrereleases: false))
        XCTAssertThrowsError(try UpdateChecker.parse(Data(#"{"message":"rate limited"}"#.utf8),
                                                     includePrereleases: false),
                             "an object where an array belongs is not a release list")
    }

    /// GitHub returns releases newest-first by date, but dates and versions can disagree
    /// (a backported patch, a re-published release), so the newest *version* is what counts.
    func testNewestIsChosenByVersionNotFeedOrder() throws {
        let out = try UpdateChecker.parse(feed([release(tag: "v0.9.0"), release(tag: "v0.10.0")]),
                                          includePrereleases: false)
        XCTAssertEqual(out.max(by: { $0.version < $1.version })?.tag, "v0.10.0")
    }
}
