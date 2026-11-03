import Foundation
import Testing
@testable import LighthouseCore

/// The Claude credential is read through `/usr/bin/security` (no Keychain prompt per Lighthouse build).
@Suite struct KeychainReadTests {
    @Test func secretOutputIsTrimmedAndHexIsDecoded() {
        #expect(ClaudeKeychainCredentials.secretData(Data("{\"a\":1}\n".utf8)) == Data("{\"a\":1}".utf8))
        #expect(ClaudeKeychainCredentials.secretData(Data("7b7d\n".utf8)) == Data("{}".utf8))
        #expect(ClaudeKeychainCredentials.secretData(Data("\n".utf8)) == nil)
    }

    /// A service name that does not exist: `security` reports "not found", which reads as missing.
    @Test func missingItemReadsAsMissing() {
        let (status, output) = ClaudeKeychainCredentials.run(arguments: ["find-generic-password", "-s", "lighthouse-test-no-such-item-\(UUID().uuidString)", "-w"])
        #expect(status == 44)
        #expect(output.isEmpty)
    }

    /// Opt-in (`LIGHTHOUSE_LIVE_KEYCHAIN=1`): the real item. Prints the result kind and seconds only.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIGHTHOUSE_LIVE_KEYCHAIN"] == "1"))
    func liveRead() {
        let started = Date()
        let result = ClaudeKeychainCredentials().load()
        let kind: String
        switch result {
        case .found(let credential): kind = "found expiresAt=\(credential.expiresAt.map { "\($0)" } ?? "nil")"
        case .missing: kind = "missing"
        case .denied: kind = "denied"
        case .unreadable: kind = "unreadable"
        }
        print("LIVE keychain result=\(kind) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
    }
}
