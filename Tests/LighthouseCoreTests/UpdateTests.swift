import Foundation
import Testing
@testable import LighthouseCore

/// SPEC 2.12: update checks, release notes for the hover, and the verified one-click install.
struct UpdateTests {
    // MARK: Versions

    @Test func versionsCompareNumerically() {
        #expect(AppVersion("v0.0.14")! > AppVersion("0.0.13")!)
        #expect(AppVersion("0.0.10")! > AppVersion("0.0.9")!)
        #expect(AppVersion("0.1")! == AppVersion("0.1.0")!)
        #expect(AppVersion("1.0.0")! > AppVersion("0.99.99")!)
        #expect(AppVersion("0.0.14")!.description == "0.0.14")
        for bad in ["", "v", "0..1", "0.0.x", "0.0.1-beta", "-1.0", "1.2.3.4.5"] { #expect(AppVersion(bad) == nil, "\(bad)") }
    }

    // MARK: Release notes

    static let body = """
    # Lighthouse 2 9.1.0

    ## Install or update

    ```sh
    curl -fsSL https://example.invalid/install.sh | sh
    ```

    Lighthouse can now do a sample thing.

    - Turn on **Sample switch** in Settings. It is off
      until you do.
    - Second change with `code`.

    Settings carry over from 9.0.0.

    ## Files

    - `Lighthouse-2-9.1.0.zip` holds only `Lighthouse 2.app`.
    """

    @Test func notesKeepTheHeadlineAndBulletsAndDropInstallAndFiles() {
        let notes = ReleaseNotes.parse(Self.body)
        #expect(notes.headline == "Lighthouse can now do a sample thing.")
        #expect(notes.items == ["Turn on **Sample switch** in Settings. It is off until you do.", "Second change with `code`."])
        #expect(ReleaseNotes.parse("").items.isEmpty)
        #expect(ReleaseNotes.parse("").headline == nil)
    }

    // MARK: Feed

    static func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, body: String? = nil,
                        base: String = UpdateFeed.downloadPrefix, zip: Bool = true) -> [String: Any] {
        let version = String(tag.dropFirst())
        var assets: [[String: Any]] = [["name": "Lighthouse-2-\(version).zip.sha256", "browser_download_url": "\(base)\(tag)/Lighthouse-2-\(version).zip.sha256"]]
        if zip { assets.append(["name": "Lighthouse-2-\(version).zip", "browser_download_url": "\(base)\(tag)/Lighthouse-2-\(version).zip"]) }
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "body": body ?? "- change in \(tag)", "assets": assets,
                "html_url": "https://github.com/\(UpdateFeed.repository)/releases/tag/\(tag)", "published_at": "2026-01-02T03:04:05Z"]
    }

    static func feed(_ items: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: items) }

    @Test func feedKeepsOnlyPublishedReleasesWithOwnAssets() throws {
        let data = Self.feed([
            Self.release("v9.3.0", draft: true),
            Self.release("v9.2.1", prerelease: true),
            Self.release("v9.2.0", base: "https://github.com/someone-else/lighthouse-2/releases/download/"),
            Self.release("v9.1.5", zip: false),
            Self.release("v9.1.0"),
            Self.release("v9.0.0"),
            ["tag_name": "not-a-version", "assets": []],
        ])
        let releases = try UpdateFeed.parse(data)
        #expect(releases.map(\.version.description) == ["9.1.0", "9.0.0"])
        #expect(releases[0].notes.items == ["change in v9.1.0"])
        #expect(releases[0].publishedAt != nil)
        #expect(throws: UpdateFeed.Failure.unreadable) { try UpdateFeed.parse(Data("{}".utf8)) }
    }

    @Test func offerListsEveryNewerReleaseNewestFirst() throws {
        let releases = try UpdateFeed.parse(Self.feed([Self.release("v9.0.0"), Self.release("v9.2.0"), Self.release("v9.1.0"), Self.release("v8.0.0")]))
        let offer = try #require(UpdateOffer(current: AppVersion("9.0.0")!, releases: releases))
        #expect(offer.releases.map(\.version.description) == ["9.2.0", "9.1.0"])
        #expect(offer.latest.version.description == "9.2.0")
        #expect(UpdateOffer(current: AppVersion("9.2.0")!, releases: releases) == nil)
        #expect(UpdateOffer(current: AppVersion("10.0")!, releases: releases) == nil)
    }

    @Test func checkReadsTheFeedThroughTheTransport() async throws {
        let transport = FakeUpdateTransport([UpdateFeed.releasesURL: Self.feed([Self.release("v9.1.0")])])
        let updater = Updater(transport: transport, workFolder: Scratch().url.appendingPathComponent("updates"))
        #expect(try await updater.check(current: AppVersion("9.1.0")!) == nil)
        #expect(try await updater.check(current: AppVersion("9.0.0")!)?.latest.version.description == "9.1.0")
        #expect(transport.requested.allSatisfy { $0 == UpdateFeed.releasesURL })
    }

    @Test func transportTrustsOnlyGitHubOverHTTPS() {
        #expect(GitHubTransport.trusted(URL(string: "https://api.github.com/repos/x")))
        #expect(GitHubTransport.trusted(URL(string: "https://release-assets.githubusercontent.com/a")))
        #expect(!GitHubTransport.trusted(URL(string: "http://github.com/a")))
        #expect(!GitHubTransport.trusted(URL(string: "https://github.com.evil.example/a")))
        #expect(!GitHubTransport.trusted(URL(string: "https://evilgithubusercontent.com/a")))
    }

    @Test func checksumFileMustHoldAHash() throws {
        let hash = String(repeating: "ab", count: 32)
        #expect(try UpdateFeed.checksum(in: Data("\(hash)  Lighthouse-2-9.1.0.zip\n".utf8)) == hash)
        #expect(throws: UpdateFeed.Failure.checksumFile) { try UpdateFeed.checksum(in: Data("nothing here".utf8)) }
        #expect(throws: UpdateFeed.Failure.checksumFile) { try UpdateFeed.checksum(in: Data()) }
    }

    // MARK: Staging

    /// A fake `Lighthouse 2.app` zipped with ditto, like `scripts/package.sh`.
    static func zippedApp(in scratch: Scratch, id: String = Updater.bundleIdentifier, version: String) throws -> Data {
        let root = scratch.dir("build-\(UUID().uuidString)")
        let app = URL(fileURLWithPath: root).appendingPathComponent(Updater.appName)
        try makeApp(at: app, id: id, version: version)
        let zip = URL(fileURLWithPath: root).appendingPathComponent("app.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
        return try Data(contentsOf: zip)
    }

    static func makeApp(at app: URL, id: String = Updater.bundleIdentifier, version: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "Lighthouse"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = app.appendingPathComponent("Contents/MacOS/Lighthouse")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func stager(_ scratch: Scratch, zip: Data, checksum: String, version: String = "9.1.0") throws -> (Updater, ReleaseInfo) {
        let release = try #require(try UpdateFeed.parse(Self.feed([Self.release("v\(version)")])).first)
        let transport = FakeUpdateTransport([release.zipURL: zip, release.checksumURL: Data("\(checksum)  Lighthouse-2-\(version).zip\n".utf8)])
        return (Updater(transport: transport, workFolder: scratch.url.appendingPathComponent("updates")), release)
    }

    @Test func stageVerifiesChecksumBundleAndVersion() async throws {
        let scratch = Scratch()
        let zip = try Self.zippedApp(in: scratch, version: "9.1.0")
        let (updater, release) = try stager(scratch, zip: zip, checksum: UpdateFeed.sha256(zip))
        let app = try await updater.stage(release)
        #expect(app.lastPathComponent == Updater.appName)
        #expect(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Lighthouse").path))
    }

    /// Must not: a download whose SHA-256 differs is never unzipped or staged.
    @Test func checksumMismatchStagesNothing() async throws {
        let scratch = Scratch()
        let zip = try Self.zippedApp(in: scratch, version: "9.1.0")
        let (updater, release) = try stager(scratch, zip: zip, checksum: String(repeating: "0", count: 64))
        await #expect(throws: UpdateFeed.Failure.checksumMismatch(expected: String(repeating: "0", count: 64), actual: UpdateFeed.sha256(zip))) {
            try await updater.stage(release)
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("updates/unzipped").path))
    }

    @Test func wrongBundleOrVersionIsRefused() async throws {
        let scratch = Scratch()
        let foreign = try Self.zippedApp(in: scratch, id: "com.example.other", version: "9.1.0")
        let (a, release) = try stager(scratch, zip: foreign, checksum: UpdateFeed.sha256(foreign))
        await #expect(throws: UpdateFeed.Failure.wrongApp("bundle id com.example.other")) { try await a.stage(release) }

        let old = try Self.zippedApp(in: scratch, version: "9.0.0")
        let (b, release2) = try stager(scratch, zip: old, checksum: UpdateFeed.sha256(old))
        await #expect(throws: UpdateFeed.Failure.wrongVersion(expected: "9.1.0", found: "9.0.0")) { try await b.stage(release2) }
    }

    @Test func stageRefusesAssetsOutsideTheRepository() async throws {
        let scratch = Scratch()
        var release = try #require(try UpdateFeed.parse(Self.feed([Self.release("v9.1.0")])).first)
        release.zipURL = URL(string: "https://example.invalid/Lighthouse-2-9.1.0.zip")!
        let updater = Updater(transport: FakeUpdateTransport([:]), workFolder: scratch.url.appendingPathComponent("updates"))
        await #expect(throws: UpdateFeed.Failure.badAsset("https://example.invalid/Lighthouse-2-9.1.0.zip")) { try await updater.stage(release) }
    }

    @Test func stageOnlyEmptiesAFolderNamedUpdates() async throws {
        let scratch = Scratch()
        let keep = scratch.write("data/keep.txt", "keep")
        let release = try #require(try UpdateFeed.parse(Self.feed([Self.release("v9.1.0")])).first)
        let updater = Updater(transport: FakeUpdateTransport([:]), workFolder: scratch.url.appendingPathComponent("data"))
        await #expect(throws: UpdateFeed.Failure.self) { try await updater.stage(release) }
        #expect(FileManager.default.fileExists(atPath: keep))
    }

    // MARK: Install script (run on scratch folders; never opens an app)

    func runInstall(scratch: Scratch, staged: URL, target: URL) throws -> (status: Int32, log: String) {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.5"]
        try sleeper.run()
        let logFile = scratch.url.appendingPathComponent("update.log")
        var env = ProcessInfo.processInfo.environment
        env["LIGHTHOUSE_UPDATE_NO_OPEN"] = "1"
        let status = try Self.run("/bin/sh", ["-c", Updater.installScript, "lighthouse-update", String(sleeper.processIdentifier),
                                              staged.path, target.path, logFile.path], environment: env)
        return (status, (try? String(contentsOf: logFile, encoding: .utf8)) ?? "")
    }

    static func version(of app: URL) -> String? {
        let data = FileManager.default.contents(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        return data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["CFBundleShortVersionString"] as? String
    }

    @Test func installScriptSwapsTheAppAfterThePidExits() throws {
        let scratch = Scratch()
        let target = URL(fileURLWithPath: scratch.dir("Applications")).appendingPathComponent(Updater.appName)
        try Self.makeApp(at: target, version: "9.0.0")
        let staged = URL(fileURLWithPath: scratch.dir("store/updates/unzipped")).appendingPathComponent(Updater.appName)
        try Self.makeApp(at: staged, version: "9.1.0")
        let result = try runInstall(scratch: scratch, staged: staged, target: target)
        #expect(result.status == 0, "\(result.log)")
        #expect(Self.version(of: target) == "9.1.0")
        #expect(result.log.contains("update: installed 9.1.0"))
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: target.path + ".previous"))
        #expect(!fm.fileExists(atPath: target.path + ".installing"))
        #expect(!fm.fileExists(atPath: scratch.url.appendingPathComponent("store/updates").path))
        #expect(fm.fileExists(atPath: scratch.url.appendingPathComponent("store").path))
    }

    /// Must not: a failed copy leaves the installed app as it was.
    @Test func installScriptKeepsTheOldAppWhenTheCopyFails() throws {
        let scratch = Scratch()
        let target = URL(fileURLWithPath: scratch.dir("Applications")).appendingPathComponent(Updater.appName)
        try Self.makeApp(at: target, version: "9.0.0")
        let missing = scratch.url.appendingPathComponent("store/updates/unzipped/\(Updater.appName)")
        let result = try runInstall(scratch: scratch, staged: missing, target: target)
        #expect(result.status != 0)
        #expect(Self.version(of: target) == "9.0.0")
        #expect(result.log.contains("old copy kept"))
        #expect(!FileManager.default.fileExists(atPath: target.path + ".installing"))
    }
}

final class FakeUpdateTransport: UpdateTransport, @unchecked Sendable {
    private let responses: [URL: Data]
    private let lock = NSLock()
    private var log: [URL] = []
    var requested: [URL] { lock.withLock { log } }

    init(_ responses: [URL: Data]) { self.responses = responses }

    func get(_ url: URL) async throws -> Data {
        lock.withLock { log.append(url) }
        guard let data = responses[url] else { throw UpdateFeed.Failure.http(404) }
        return data
    }
}

/// Live probe: `LIGHTHOUSE_LIVE_UPDATES=1 swift test --filter LiveUpdateProbe` reads the real public
/// release list and prints what a 0.0.2 copy would be offered. Skipped otherwise.
struct LiveUpdateProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_UPDATES"] == "1"))
    func realFeedParses() async throws {
        let updater = Updater(workFolder: Scratch().url.appendingPathComponent("updates"))
        let offer = try #require(try await updater.check(current: AppVersion("0.0.2")!))
        #expect(offer.releases.count >= 11)
        for release in offer.releases {
            print("\(release.version) \(release.zipURL.absoluteString)\n  headline: \(release.notes.headline ?? "-")")
            for item in release.notes.items { print("  • \(item)") }
            #expect(!release.notes.items.isEmpty || release.notes.headline != nil, "\(release.version) has no notes")
        }
    }
}
