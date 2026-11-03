import Foundation
import Testing
@testable import LighthouseCore

/// SPEC §11 shared must-not checks that run as unit tests.
@Suite struct MustNotTests {
    func index(_ s: Scratch, access: SourceAccess = ReadOnlyFileSystem()) async throws -> (Store, URL) {
        let dir = s.url.appendingPathComponent("AppSupport/Lighthouse")
        let store = try Store(url: dir.appendingPathComponent("lighthouse.sqlite"))
        let engine = Engine(collectors: [ClaudeCodeCollector(root: s.claudeRoot, access: access, store: store),
                                         CodexCollector(codexHome: s.codexHome, access: access, store: store)],
                            store: store, home: s.path)
        _ = await engine.indexToCompletion()
        try store.savePrefs(ProjectPrefs(pinned: ["/Users/me/Projects/alpha"]))
        return (store, dir)
    }

    func assertNoCanary(in dir: URL, includeWALBeforeCheckpoint store: Store) {
        let fm = FileManager.default
        var files = (fm.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).map { dir.appendingPathComponent($0).path }
        files.append(contentsOf: (try? fm.contentsOfDirectory(atPath: NSTemporaryDirectory()))?
            .filter { $0.hasPrefix("lighthouse") || $0.hasPrefix("Lighthouse") }
            .map { (NSTemporaryDirectory() as NSString).appendingPathComponent($0) } ?? [])
        #expect(files.contains { $0.hasSuffix("lighthouse.sqlite-wal") })
        for file in files {
            #expect(!bytesContain(file, Fixture.bodyCanary), "body canary in \(file)")
            #expect(!bytesContain(file, Fixture.secretCanary), "secret canary in \(file)")
        }
        store.checkpointWAL()
        for file in files {
            #expect(!bytesContain(file, Fixture.bodyCanary), "body canary in \(file)")
            #expect(!bytesContain(file, Fixture.secretCanary), "secret canary in \(file)")
        }
    }

    @Test func canariesNeverReachTheStoreWALOrAppFolder() async throws {
        let s = Scratch()
        s.installFixtures()
        // The fixtures do contain both canaries in message, tool, and error fields.
        #expect(bytesContain(s.claudeRoot + "/-Users-me-Projects-alpha/\(Fixture.claudeSession).jsonl", Fixture.bodyCanary))
        #expect(bytesContain(s.codexHome + "/sessions/2026/10/29/rollout-2026-10-29T10-00-00-\(Fixture.codexParent).jsonl", Fixture.secretCanary))
        let (store, dir) = try await index(s)
        assertNoCanary(in: dir, includeWALBeforeCheckpoint: store)
    }

    @Test func canariesAbsentAfterForcedErrors() async throws {
        let s = Scratch()
        s.installFixtures()
        // Malformed records carrying canaries, an over-long line, and an unreadable file.
        s.append("claude/-Users-me-Projects-alpha/\(Fixture.claudeSession).jsonl",
                 "{\"type\":\"user\",\"message\":{\"content\":\"\(Fixture.bodyCanary) \(Fixture.secretCanary)\"\n" +
                 "{\"type\":\"assistant\",\"timestamp\":12,\"message\":{\"id\":{\"x\":\"\(Fixture.secretCanary)\"}}}\n" +
                 String(repeating: Fixture.bodyCanary, count: 70_000) + "\n")
        let locked = s.write("claude/-Users-me-Projects-alpha/55555555-5555-4555-8555-555555555555.jsonl",
                             "{\"cwd\":\"\(Fixture.secretCanary)\",\"type\":\"user\",\"timestamp\":\"2026-10-29T10:00:00.000Z\"}\n")
        chmod(locked, 0)
        defer { chmod(locked, 0o644) }
        let (store, dir) = try await index(s)
        assertNoCanary(in: dir, includeWALBeforeCheckpoint: store)
        let statuses = try store.loadStatuses()
        #expect(statuses.allSatisfy { $0.error.map { !$0.contains(Fixture.secretCanary) } ?? true })
    }

    @Test func persistedSchemaMatchesAllowlist() async throws {
        let s = Scratch()
        s.installFixtures()
        let (store, _) = try await index(s)
        let schema = try store.schema()
        #expect(Set(schema.keys) == Set(Store.schemaAllowlist.keys))
        for (table, columns) in schema { #expect(Set(columns) == Set(Store.schemaAllowlist[table] ?? []), "table \(table)") }
    }

    /// Keys allowed inside checkpoint `state_json`: ids, paths, title fields, times, counters, flags.
    static let stateKeyAllowlist: Set<String> = [
        // ClaudeFileState
        "sessionId", "agentId", "isChild", "agentType", "model", "cwd", "gitBranch", "entrypoint", "startedAt", "lastActivityAt",
        "lastProgressAt", "lastTurnRecordAt", "lastTurnKind", "summaryTitle", "customTitle", "tokens", "recentMessageIds", "tokenBuckets",
        // CodexFileState
        "id", "originator", "repositoryURL", "parentThreadId", "agentName", "turnOpen", "turnStartedAt", "lastTotalTokens", "tokenEpochs", "tokensPartial",
        // CodexIndexState
        "titles",
    ]

    @Test func checkpointStateKeysMatchAllowlist() async throws {
        let s = Scratch()
        s.installFixtures()
        let (store, _) = try await index(s)
        var keys = Set<String>()
        for source in SourceKind.allCases {
            for (_, c) in store.loadCheckpoints(source: source) {
                let object = try #require(try JSONSerialization.jsonObject(with: c.state) as? [String: Any])
                keys.formUnion(object.keys)
            }
        }
        #expect(!keys.isEmpty)
        #expect(keys.isSubset(of: Self.stateKeyAllowlist), "unexpected keys: \(keys.subtracting(Self.stateKeyAllowlist))")
    }

    /// No-copy guard: collectors touch sources only through read-only operations, the source tree is
    /// unchanged on success and failure paths, and nothing source-sized appears in the app folder.
    @Test func sourcesAreReadInPlaceOnly() async throws {
        let s = Scratch()
        s.installFixtures()
        let before = treeFingerprint(s.claudeRoot).merging(treeFingerprint(s.codexHome)) { a, _ in a }
        let access = RecordingAccess()
        let (_, dir) = try await index(s, access: access)
        #expect(Set(access.operations.map(\.op)).isSubset(of: ["stat", "isReadable", "list", "read", "scan"]))
        #expect(access.operations.allSatisfy { $0.path.hasPrefix(s.claudeRoot) || $0.path.hasPrefix(s.codexHome) })

        let failing = RecordingAccess()
        failing.failReads = true
        _ = try await index(s, access: failing)
        let after = treeFingerprint(s.claudeRoot).merging(treeFingerprint(s.codexHome)) { a, _ in a }
        #expect(before == after)

        let appFiles = FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []
        #expect(Set(appFiles).isSubset(of: ["lighthouse.sqlite", "lighthouse.sqlite-wal", "lighthouse.sqlite-shm"]))
        #expect(!appFiles.contains { $0.hasSuffix(".jsonl") })
    }

    /// Symlinked entries are counted, never followed or read.
    @Test func symlinksAreNotFollowed() async throws {
        let s = Scratch()
        s.installFixtures()
        let outside = s.dir("external/2026/01")
        s.write("external/2026/01/rollout-x.jsonl",
                #"{"timestamp":"2026-10-29T10:00:00.000Z","ordinal":0,"type":"session_meta","payload":{"id":"ext","cwd":"/x"}}"# + "\n")
        try FileManager.default.createSymbolicLink(atPath: s.codexHome + "/sessions/2026/01", withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: s.codexHome + "/sessions/2026/10/29/linked.jsonl",
                                                   withDestinationPath: outside + "/rollout-x.jsonl")
        let access = RecordingAccess()
        let result = await CodexCollector(codexHome: s.codexHome, access: access).pass(now: Date())
        #expect(!result.threads.contains { $0.sessionId == "ext" })
        #expect(result.status.filesNotIndexed == 2)
        #expect(!access.operations.contains { $0.path.hasPrefix(s.path + "/external") || ($0.op == "read" && $0.path.hasSuffix("linked.jsonl")) })
    }

    /// Static guard: no file-copy/move/write API is used anywhere in LighthouseCore except the store's
    /// own folder creation. Networking (M2) is confined to `UsageLive.swift` (one client session, no
    /// listener); the only URL literals in the package are the two usage endpoints (SPEC §2 V-NET);
    /// nothing refreshes a token (SPEC §4).
    @Test func coreSourceUsesNoCopyOrNetworkAPIs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LighthouseCore")
        let forbidden = ["copyItem", "moveItem", "linkItem", "replaceItem", "removeItem", "createFile", "copyfile", "clonefile",
                         "NWConnection", "NWListener", "socket(", "bind(", "listen(", "CFSocket", "O_WRONLY", "O_RDWR",
                         "write(to", "FileHandle(forWriting", "FileHandle(forUpdating",
                         "refresh_token", "refreshToken", "grant_type", "oauth/token", "webSocketTask", "uploadTask", "downloadTask",
                         "SecItemAdd", "SecItemUpdate", "SecItemDelete", "print(", "NSLog", "Logger("]
        let networkOnly = ["URLSession", "URLRequest"]
        var urls: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            // SPEC 2.11: T3Link alone may write and delete its token file and exchange a T3 pairing
            // code for a token; every other forbidden word stays forbidden there too.
            let t3LinkAllowed: Set<String> = ["write(to", "removeItem", "grant_type"]
            // "removeItem" contains "moveItem"; T3Link is checked for moveItem without it.
            let checked = name == "T3Link.swift" ? text.replacingOccurrences(of: "removeItem", with: "") : text
            for word in forbidden where !(name == "T3Link.swift" && t3LinkAllowed.contains(word)) {
                #expect(!checked.contains(word), "\(name) uses \(word)")
            }
            if name != "UsageLive.swift" && name != "T3Link.swift" { for word in networkOnly { #expect(!text.contains(word), "\(name) uses \(word)") } }
            for line in text.split(separator: "\n") where line.contains("://") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                var rest = Substring(line)
                while let range = rest.range(of: "https://") ?? rest.range(of: "http://") {
                    let tail = rest[range.lowerBound...]
                    let end = tail.firstIndex(where: { $0 == "\"" || $0 == " " || $0 == "`" }) ?? tail.endIndex
                    let url = String(tail[..<end])
                    if !url.hasSuffix("://") { urls.append(url) }
                    rest = tail[end...]
                }
            }
        }
        // The T3 server on this Mac (SPEC 2.11) and the redirect address T3 is told about (nothing listens there).
        #expect(Set(urls) == ["https://api.anthropic.com/api/oauth/usage", "https://chatgpt.com/backend-api/wham/usage",
                              "http://127.0.0.1:3773", "http://127.0.0.1:51829/t3-callback"], "\(urls)")
        #expect(UsageEndpoints.allowed.map(\.absoluteString).sorted() == ["https://api.anthropic.com/api/oauth/usage", "https://chatgpt.com/backend-api/wham/usage"])
    }
}
