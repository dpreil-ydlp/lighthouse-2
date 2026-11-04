import CryptoKit
import Foundation

/// App updates (SPEC 2.12): find newer GitHub releases of Lighthouse 2, list what changes, and
/// stage a verified copy of the newest one for the app to swap in.
///
/// Network and disk use are confined to this file (guarded in `MustNotTests`): HTTPS GET of the
/// public release list and of the release zip and its `.sha256` file, and writes inside the
/// updates work folder only.

/// A dotted release version ("0.0.14", tag "v0.0.14"). Missing parts count as 0.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let number = Int(piece), number >= 0 else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}

/// What a release changes, read from its GitHub release text: the opening sentence and the
/// bullet points. The install command and the file list are left out.
public struct ReleaseNotes: Hashable, Sendable {
    public var headline: String?
    public var items: [String]

    public init(headline: String?, items: [String]) {
        self.headline = headline
        self.items = items
    }

    static let skippedSections = ["install", "files", "download", "checksum"]
    /// The "Install or update" section is the command block only; release notes follow it with no heading.
    static let endsAfterCode = ["install"]

    public static func parse(_ body: String) -> ReleaseNotes {
        var headline: String?
        var items: [String] = []
        var paragraph: [String] = []
        var inFence = false
        var skipping = false
        var skipEndsAfterCode = false
        var current: String?

        func endItem() {
            if let item = current?.trimmingCharacters(in: .whitespaces), !item.isEmpty { items.append(item) }
            current = nil
        }
        func endParagraph() {
            if headline == nil, items.isEmpty, !paragraph.isEmpty { headline = paragraph.joined(separator: " ") }
            paragraph = []
        }

        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                endItem(); endParagraph()
                inFence.toggle()
                if !inFence && skipEndsAfterCode { skipping = false; skipEndsAfterCode = false }
                continue
            }
            if inFence { continue }
            if trimmed.hasPrefix("#") {
                endItem(); endParagraph()
                let title = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).lowercased()
                // A level-1 heading is the release title ("Lighthouse 2 0.0.13"); it ends a skipped section.
                skipping = !trimmed.hasPrefix("# ") && skippedSections.contains { title.hasPrefix($0) }
                skipEndsAfterCode = skipping && endsAfterCode.contains { title.hasPrefix($0) }
                continue
            }
            if skipping { continue }
            if trimmed.isEmpty {
                endItem(); endParagraph()
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                endItem(); endParagraph()
                current = String(trimmed.dropFirst(2))
            } else if current != nil, line.hasPrefix(" ") {
                current! += " " + trimmed
            } else {
                endItem()
                paragraph.append(trimmed)
            }
        }
        endItem(); endParagraph()
        return ReleaseNotes(headline: headline, items: items)
    }
}

/// One published release that has a zip and its checksum file.
public struct ReleaseInfo: Hashable, Sendable {
    public var version: AppVersion
    public var tag: String
    public var notes: ReleaseNotes
    public var zipURL: URL
    public var checksumURL: URL
    public var pageURL: URL?
    public var publishedAt: Date?

    public init(version: AppVersion, tag: String, notes: ReleaseNotes, zipURL: URL, checksumURL: URL, pageURL: URL? = nil, publishedAt: Date? = nil) {
        self.version = version
        self.tag = tag
        self.notes = notes
        self.zipURL = zipURL
        self.checksumURL = checksumURL
        self.pageURL = pageURL
        self.publishedAt = publishedAt
    }
}

/// The releases newer than the running copy, newest first. `latest` is the one installed.
public struct UpdateOffer: Hashable, Sendable {
    public var current: AppVersion
    public var releases: [ReleaseInfo]
    public var latest: ReleaseInfo { releases[0] }

    public init?(current: AppVersion, releases: [ReleaseInfo]) {
        let newer = releases.filter { $0.version > current }.sorted { $0.version > $1.version }
        guard !newer.isEmpty else { return nil }
        self.current = current
        self.releases = newer
    }
}

/// The public release list of Lighthouse 2 on GitHub.
public enum UpdateFeed {
    public static let repository = "dpreil-ydlp/lighthouse-2"
    public static let releasesURL = URL(string: "https://api.github.com/repos/dpreil-ydlp/lighthouse-2/releases?per_page=20")!
    /// Assets must come from this repository's own release downloads.
    public static let downloadPrefix = "https://github.com/dpreil-ydlp/lighthouse-2/releases/download/"
    public static let zipPrefix = "Lighthouse-2-"

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable
        case offline(String)
        case http(Int)
        case badAsset(String)
        case checksumFile
        case checksumMismatch(expected: String, actual: String)
        case unzip
        case wrongApp(String)
        case wrongVersion(expected: String, found: String)
        case notWritable(String)

        public var description: String {
            switch self {
            case .unreadable: "the release list could not be read"
            case .offline(let reason): "GitHub could not be reached (\(reason))"
            case .http(let status): "GitHub answered HTTP \(status)"
            case .badAsset(let url): "refused a download outside the Lighthouse 2 releases: \(url)"
            case .checksumFile: "the checksum file does not hold a SHA-256 hash"
            case .checksumMismatch: "the download does not match its SHA-256; nothing was installed"
            case .unzip: "the download could not be unzipped"
            case .wrongApp(let reason): "the download is not Lighthouse 2 (\(reason))"
            case .wrongVersion(let expected, let found): "the download is version \(found), not \(expected)"
            case .notWritable(let path): "Lighthouse 2 cannot replace itself at \(path); move it to Applications and try again"
            }
        }
    }

    /// Published, non-draft, non-prerelease releases with a `Lighthouse-2-<version>.zip` and its
    /// `.sha256`. With `allowFileAssets` (test mode only) assets may be `file://` URLs.
    public static func parse(_ data: Data, allowFileAssets: Bool = false) throws -> [ReleaseInfo] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.unreadable }
        let iso = ISO8601DateFormatter()
        return list.compactMap { item in
            guard item["draft"] as? Bool != true, item["prerelease"] as? Bool != true,
                  let tag = item["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
            let assets = (item["assets"] as? [[String: Any]]) ?? []
            func asset(_ name: String) -> URL? {
                guard let entry = assets.first(where: { $0["name"] as? String == name }),
                      let text = entry["browser_download_url"] as? String, let url = URL(string: text),
                      allowed(url, tag: tag, allowFileAssets: allowFileAssets) else { return nil }
                return url
            }
            let zipName = "\(zipPrefix)\(version).zip"
            guard let zip = asset(zipName), let sum = asset(zipName + ".sha256") else { return nil }
            return ReleaseInfo(version: version, tag: tag, notes: ReleaseNotes.parse(item["body"] as? String ?? ""),
                               zipURL: zip, checksumURL: sum, pageURL: (item["html_url"] as? String).flatMap(URL.init(string:)),
                               publishedAt: (item["published_at"] as? String).flatMap(iso.date(from:)))
        }
    }

    static func allowed(_ url: URL, tag: String, allowFileAssets: Bool) -> Bool {
        if allowFileAssets, url.isFileURL { return true }
        return url.scheme == "https" && url.absoluteString.hasPrefix(downloadPrefix + tag + "/")
    }

    /// The first SHA-256 hash in a `shasum -a 256` file.
    public static func checksum(in data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let first = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first else { throw Failure.checksumFile }
        let hash = first.lowercased()
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw Failure.checksumFile }
        return hash
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// GET only. `https` to GitHub hosts (redirects included), or `file://` in test mode.
public protocol UpdateTransport: Sendable {
    func get(_ url: URL) async throws -> Data
}

public struct GitHubTransport: UpdateTransport {
    public var allowFiles: Bool

    public init(allowFiles: Bool = false) { self.allowFiles = allowFiles }

    static func trusted(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "api.github.com" || host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    public func get(_ url: URL) async throws -> Data {
        if url.isFileURL {
            guard allowFiles, let data = FileManager.default.contents(atPath: url.path) else { throw UpdateFeed.Failure.badAsset(url.absoluteString) }
            return data
        }
        guard Self.trusted(url) else { throw UpdateFeed.Failure.badAsset(url.absoluteString) }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lighthouse-2-updater", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: GitHubRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw UpdateFeed.Failure.offline(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw UpdateFeed.Failure.unreadable }
        guard http.statusCode == 200 else { throw UpdateFeed.Failure.http(http.statusCode) }
        return data
    }

    /// Release downloads redirect from github.com to a githubusercontent.com host; nothing else is followed.
    private final class GitHubRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            GitHubTransport.trusted(request.url) ? request : nil
        }
    }
}

/// Checks for and stages updates. The swap itself happens after the app quits (`installScript`).
public struct Updater: Sendable {
    public static let bundleIdentifier = "com.lighthouse.v2"
    public static let appName = "Lighthouse 2.app"

    public var transport: UpdateTransport
    public var feedURL: URL
    /// Holds downloads and the unzipped copy; emptied before each download.
    public var workFolder: URL
    public var allowFileAssets: Bool
    public var launcher: SummaryProcessLauncher

    public init(transport: UpdateTransport = GitHubTransport(), feedURL: URL = UpdateFeed.releasesURL, workFolder: URL,
                allowFileAssets: Bool = false, launcher: SummaryProcessLauncher = SystemProcessLauncher()) {
        self.transport = transport
        self.feedURL = feedURL
        self.workFolder = workFolder
        self.allowFileAssets = allowFileAssets
        self.launcher = launcher
    }

    /// Nil when the running copy is the newest release.
    public func check(current: AppVersion) async throws -> UpdateOffer? {
        let releases = try UpdateFeed.parse(try await transport.get(feedURL), allowFileAssets: allowFileAssets)
        return UpdateOffer(current: current, releases: releases)
    }

    /// Downloads `release`, checks its SHA-256, unzips it and checks the app inside: bundle id
    /// `com.lighthouse.v2` and the release's version. Returns the staged `Lighthouse 2.app`.
    public func stage(_ release: ReleaseInfo) async throws -> URL {
        for url in [release.zipURL, release.checksumURL] where !UpdateFeed.allowed(url, tag: release.tag, allowFileAssets: allowFileAssets) {
            throw UpdateFeed.Failure.badAsset(url.absoluteString)
        }
        let fm = FileManager.default
        // Only ever empties its own folder.
        guard workFolder.lastPathComponent == "updates" else { throw UpdateFeed.Failure.notWritable(workFolder.path) }
        try? fm.removeItem(at: workFolder)
        try fm.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let zipData = try await transport.get(release.zipURL)
        let expected = try UpdateFeed.checksum(in: try await transport.get(release.checksumURL))
        let actual = UpdateFeed.sha256(zipData)
        guard expected == actual else { throw UpdateFeed.Failure.checksumMismatch(expected: expected, actual: actual) }
        let zip = workFolder.appendingPathComponent("update.zip")
        try zipData.write(to: zip, options: .atomic)
        let unzipped = workFolder.appendingPathComponent("unzipped", isDirectory: true)
        let outcome = await launcher.run(SummaryCommand(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, unzipped.path],
                                                        environment: [:], directory: workFolder.path), input: Data(), timeout: 120)
        guard outcome.exitCode == 0, !outcome.timedOut else { throw UpdateFeed.Failure.unzip }
        let app = unzipped.appendingPathComponent(Self.appName, isDirectory: true)
        try Self.verify(app: app, version: release.version)
        return app
    }

    /// The staged app must be Lighthouse 2 at `version`.
    public static func verify(app: URL, version: AppVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateFeed.Failure.wrongApp("no \(appName) in the zip")
        }
        let id = info["CFBundleIdentifier"] as? String ?? "none"
        guard id == bundleIdentifier else { throw UpdateFeed.Failure.wrongApp("bundle id \(id)") }
        let found = info["CFBundleShortVersionString"] as? String ?? "none"
        guard AppVersion(found) == version else { throw UpdateFeed.Failure.wrongVersion(expected: version.description, found: found) }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/Lighthouse").path) else {
            throw UpdateFeed.Failure.wrongApp("no Lighthouse executable")
        }
    }

    /// Lighthouse can replace `target` only if it may write to the folder that holds it.
    public static func canReplace(_ target: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: target.path)
    }

    /// `/bin/sh` script run detached after the app quits. Arguments: the app's PID, the staged
    /// copy, the installed copy, the log file, then the launch arguments for the new copy. It waits
    /// up to 30 s for the PID to exit, copies the staged app next to the target, swaps it in (the
    /// old copy is put back if the swap fails), then opens the target, retrying for up to 10 s. `open -n`:
    /// the old process has exited, and a plain `open` could only bring forward another running copy.
    public static let installScript = #"""
    pid="$1"; new="$2"; target="$3"; logfile="$4"; shift 4
    exec >>"$logfile" 2>&1
    echo "update: start $(date -u +%FT%TZ) pid=$pid target=$target"
    n=0
    while kill -0 "$pid" 2>/dev/null; do
        n=$((n + 1))
        if [ "$n" -gt 150 ]; then echo "update: app did not quit; nothing changed"; exit 1; fi
        sleep 0.2
    done
    reopen() {
        # Tests swap a scratch copy and never open it.
        if [ "${LIGHTHOUSE_UPDATE_NO_OPEN:-0}" = "1" ]; then echo "update: not opening"; return 0; fi
        exe="$target/Contents/MacOS/Lighthouse"
        tries=0
        while [ "$tries" -lt 10 ]; do
            tries=$((tries + 1))
            if /usr/bin/open -n "$target" --args "$@"; then
                waited=0
                while [ "$waited" -lt 5 ]; do
                    if /bin/ps -axww -o comm= | /usr/bin/grep -Fqx "$exe"; then echo "update: running"; return 0; fi
                    waited=$((waited + 1)); sleep 1
                done
            fi
            sleep 1
        done
        echo "update: installed but macOS did not start it"
        return 1
    }
    /bin/rm -rf "$target.installing" "$target.previous"
    if ! /usr/bin/ditto "$new" "$target.installing"; then
        /bin/rm -rf "$target.installing"
        echo "update: copy failed; old copy kept"
        reopen "$@"; exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$target.installing" 2>/dev/null
    if ! /bin/mv "$target" "$target.previous"; then
        /bin/rm -rf "$target.installing"
        echo "update: could not move the old copy; old copy kept"
        reopen "$@"; exit 1
    fi
    if ! /bin/mv "$target.installing" "$target"; then
        /bin/mv "$target.previous" "$target"
        /bin/rm -rf "$target.installing"
        echo "update: swap failed; old copy restored"
        reopen "$@"; exit 1
    fi
    /bin/rm -rf "$target.previous"
    work="$(dirname "$(dirname "$new")")"
    case "$work" in */updates) /bin/rm -rf "$work" ;; esac
    echo "update: installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$target/Contents/Info.plist")"
    reopen "$@"
    """#

    /// Starts the install script, detached; the caller quits the app right after.
    public static func launchInstall(pid: Int32, staged: URL, target: URL, logFile: URL, arguments: [String]) -> Bool {
        SystemProcessLauncher.launchDetached(executable: "/bin/sh",
                                             arguments: ["-c", installScript, "lighthouse-update", String(pid), staged.path, target.path, logFile.path] + arguments)
    }
}
