import Foundation
import Testing
@testable import LighthouseCore

/// M8-E03: redaction is linear-time on any input. Each adversarial shape must redact in well under
/// a 50 ms target; the assertion uses a generous 250 ms bound so a loaded machine does
/// not flake, and every measured time is printed for the receipt.
struct RedactionPerformanceTests {
    static let bound: Duration = .milliseconds(250)
    /// The 1 MB bound: 1 s in a release build (what ships); unoptimized builds only check the budget.
    #if DEBUG
    static let megabyteBound: Duration = .seconds(2)   // `Redactor.budget`
    #else
    static let megabyteBound: Duration = .seconds(1)
    #endif

    /// Fastest of three runs, so a scheduler hiccup on a loaded machine is not read as slowness.
    static func time(_ text: String) -> Duration {
        let clock = ContinuousClock()
        return (0..<3).map { _ in clock.measure { _ = Redactor.redact(text) } }.min()!
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
    static let kb24 = 24 * 1024

    /// Repeats `unit` until the text is at least `bytes` long.
    static func fill(_ unit: String, _ bytes: Int = kb24) -> String {
        String(repeating: unit, count: bytes / unit.utf8.count + 1)
    }

    /// Deterministic noise over the characters the patterns care about.
    static func noise(_ bytes: Int = kb24) -> String {
        let alphabet = Array("aZ09_-=:\"'`\\ \t,;&/@.+~eyJskAK-----BEGIN token password Bearer ://\n".utf8)
        var state: UInt64 = 0x9E3779B97F4A7C15
        var out = [UInt8]()
        out.reserveCapacity(bytes)
        for _ in 0..<bytes {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(alphabet[Int(state >> 33) % alphabet.count])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static let shapes: [(String, String)] = [
        // Sol's reproduction (M8-E03), growing, so a quadratic matcher shows its curve.
        ("sol a- 1 KB", String(repeating: "a-", count: 512)),
        ("sol a- 2 KB", String(repeating: "a-", count: 1024)),
        ("sol a- 4 KB", String(repeating: "a-", count: 2048)),
        ("hyphen run 24 KB", fill("-")),
        ("underscore run a_ 24 KB", fill("a_")),
        ("mixed run a-b_ 24 KB", fill("a-b_")),
        ("many = 24 KB", fill("=")),
        ("a= 24 KB", fill("a=")),
        ("many double quotes 24 KB", fill("\"")),
        ("many single quotes 24 KB", fill("'")),
        ("many backticks 24 KB", fill("`")),
        ("backslashes in a quoted value 24 KB", "password=\"" + fill("\\")),
        ("single word line 24 KB", fill("abcdefgh")),
        ("password= repeats 24 KB", fill("password=")),
        ("password=\" repeats 24 KB", fill("password=\"")),
        ("password: then a- run 24 KB", "password: " + fill("a-")),
        ("api-key- repeats 24 KB", fill("api-key-")),
        ("Authorization: repeats 24 KB", fill("Authorization: ")),
        ("Bearer repeats 24 KB", fill("Bearer ")),
        ("scheme run a. 24 KB", fill("a.")),
        ("scheme then :// 24 KB", "a://x:" + fill("y")),
        ("eyJ- repeats 24 KB", fill("eyJ-")),
        ("eyJ word 24 KB", "eyJ" + fill("a")),
        ("sk- repeats 24 KB", fill("sk-")),
        ("BEGIN repeats 24 KB", fill("-----BEGIN ")),
        ("BEGIN then caps 24 KB", "-----BEGIN " + fill("A ")),
        ("noise 24 KB", noise()),
        ("sol a- 24 KB", String(repeating: "a-", count: 12 * 1024)),
    ]

    /// Unbuffered (stderr), so a run killed while redacting still shows every finished shape.
    static func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    @Test func everyAdversarialShapeRedactsQuickly() {
        for (name, text) in Self.shapes {
            Self.log("REDACT start shape=\"\(name)\" bytes=\(text.utf8.count)")
            let elapsed = Self.time(text)
            let ms = Self.ms(elapsed)
            Self.log("REDACT shape=\"\(name)\" bytes=\(text.utf8.count) ms=\(String(format: "%.2f", ms))")
            #expect(elapsed < Self.bound, "\(name): \(ms) ms")
        }
    }

    /// The largest text redaction can see: the tail reader gathers whole messages up to ~32 KB, plus
    /// one message of at most 1 MB (`TranscriptTail.maxLine`). Linear time keeps it far below the
    /// redaction budget.
    @Test func oneMegabyteMessageRedactsWellInsideTheBudget() {
        for (name, text) in [("sol a- 1 MB", String(repeating: "a-", count: 512 * 1024)), ("noise 1 MB", Self.noise(1 << 20))] {
            Self.log("REDACT start shape=\"\(name)\" bytes=\(text.utf8.count)")
            let elapsed = Self.time(text)
            let ms = Self.ms(elapsed)
            Self.log("REDACT shape=\"\(name)\" bytes=\(text.utf8.count) ms=\(String(format: "%.2f", ms))")
            #expect(elapsed < Self.megabyteBound, "\(name): \(ms) ms")
        }
    }
}

/// M8-E03: the linear scanner keeps the E01 rules. The candidate `c8b075b` regex rules (quadratic, so
/// only short inputs) and the new redactor must agree on thousands of seeded random inputs built from
/// keys, separators, quotes, escapes, newlines and markers. Shapes the new anchors change on purpose
/// (`eyJ` and `://` after a hyphen, an `authorization` key with a prefix) are covered by explicit
/// cases, not generated here.
struct RedactionEquivalenceTests {
    /// `Redactor` patterns exactly as in `c8b075b` (`Sources/LighthouseCore/Summaries.swift`).
    enum CandidateRedactor {
        static let marker = "[redacted]"
        static let assignment = #"(?i)\b([A-Za-z0-9_\-]*(?:password|passwd|pwd|passphrase|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|authorization|credentials?)["'`]?[ \t]*[:=][ \t]*)"#
        static let unquotedValue = #"(?!(?:[A-Za-z]+[ \t]+)?\[redacted\])[^\s"'`,;&][^\n,;&]*"#
        static let patterns: [(NSRegularExpression, String)] = [
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)"#, marker),
            (#"sk-ant-[A-Za-z0-9_\-]{8,}"#, marker),
            (#"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#, marker),
            (#"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, marker),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, marker),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, marker),
            (#"\bglpat-[A-Za-z0-9_\-]{20,}"#, marker),
            (#"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#, marker),
            (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, marker),
            (#"\bAIza[0-9A-Za-z_\-]{35}"#, marker),
            (#"\bnpm_[A-Za-z0-9]{36}\b"#, marker),
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, marker),
            (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{16,}"#, "Bearer " + marker),
            (assignment + #""(?:[^"\\\n]|\\[^\n])*"?"#, "$1\"" + marker + "\""),
            (assignment + #"'(?:[^'\\\n]|\\[^\n])*'?"#, "$1'" + marker + "'"),
            (assignment + #"`[^`\n]*`?"#, "$1`" + marker + "`"),
            (#"(?i)\b(authorization["'`]?[ \t]*[:=][ \t]*(?:bearer|basic|digest|token)[ \t]+)"# + unquotedValue, "$1" + marker),
            (assignment + unquotedValue, "$1" + marker),
            (#"\b[a-z][a-z0-9+.\-]*://[^\s:/@]+:[^\s@/]+@"#, "scheme://" + marker + "@"),
        ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

        static func redact(_ text: String) -> String {
            var result = text
            for (regex, template) in patterns {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
            }
            return result
        }
    }

    static let pieces = [
        "password", "PASSWORD", "Passwd", "pwd", "passphrase", "token", "TOKEN", "api_key", "api-key", "apikey", "secret",
        "client_secret", "access_key", "private-key", "credentials", "DB_", "--", "x", "ab", "1", "a-", "_",
        "=", "=", ":", ":", " ", " ", "\t", "\"", "\"", "'", "'", "`", "\\", "\\\"", ",", ";", "&", "\n", "\r",
        "[redacted]", "Basic [redacted]", "Bearer ", "bearer abcdefghijklmnopqrstu", "sk-ant-abcdefgh12",
        "hello", "correct horse", "is", "the", ".", "{", "}",
    ]

    @Test func scannerMatchesTheCandidateRulesOnRandomInputs() {
        var state: UInt64 = 0xC0FFEE
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }
        var mismatches: [(String, String, String)] = []
        let total = 10_000
        for _ in 0..<total {
            var text = ""
            for _ in 0..<(1 + next(60)) { text += Self.pieces[next(Self.pieces.count)] }
            let expected = CandidateRedactor.redact(text)
            let actual = Redactor.redact(text)
            if actual != expected { mismatches.append((text, expected, actual)) }
        }
        for (text, expected, actual) in mismatches.prefix(10) {
            Issue.record("input \(text.debugDescription)\n  candidate \(expected.debugDescription)\n  new       \(actual.debugDescription)")
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) of \(total) differ")
    }

    /// Found by the random comparison while building the scanner: an unquoted value must not end at a
    /// `;` or `,` inside a later key's quoted value (quoted values go first, as in the E01 rules).
    @Test func unquotedValueNeverSplitsALaterQuotedValue() {
        #expect(Redactor.redact(#"token=abc secret="x; y""#) == "token=[redacted]")
        #expect(Redactor.redact("pwd=a, api_key='b, c' tail") == "pwd=[redacted], api_key='[redacted]' tail")
        #expect(Redactor.redact("user=bob, password=\"p, q\"\nnext line") == "user=bob, password=\"[redacted]\"\nnext line")
    }

    /// The deliberate changes: anchored JWT and URL starts, and a prefixed `authorization` key.
    @Test func anchoredShapesStillRedactTheirSecrets() {
        // Fake values are split so secret scanners do not flag the test source; the strings are unchanged.
        let jwt: String = ("eyJhbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0" + ".dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U")
        #expect(Redactor.redact("token \(jwt) end") == "token [redacted] end")
        #expect(Redactor.redact("(\(jwt))") == "([redacted])")
        // M8-E04: a JWT right after `-` or `.` (markdown bullet, id prefix) is still removed.
        #expect(Redactor.redact("-" + jwt) == "-[redacted]")
        #expect(Redactor.redact("- " + jwt) == "- [redacted]")
        #expect(Redactor.redact("prefix-" + jwt + " end") == "prefix-[redacted] end")
        #expect(Redactor.redact("a." + jwt) == "a.[redacted]")
        #expect(Redactor.redact("abc" + jwt) == "abc" + jwt)   // no word boundary, as `\b` before
        #expect(Redactor.redact("see https://admin:s3cret@db.local/x") == "see scheme://[redacted]@db.local/x")
        #expect(Redactor.redact("url=postgres://u:p@h") == "url=scheme://[redacted]@h")
        #expect(Redactor.redact("X-Authorization: Basic dXNlcjpwYXNz") == "X-Authorization: Basic [redacted]")
        #expect(Redactor.redact("proxyAuthorization: Basic dXNlcjpwYXNz") == "proxyAuthorization: Basic [redacted]")
    }

    // M8-E04 repair keeps M8-E03 linear: JWT-start runs that never complete a token.
    @Test func jwtScanStaysLinearOnAdversarialRuns() {
        let shapes = [String(repeating: "eyJ-", count: 6_144),
                      String(repeating: "eyJaaaaaaaa.", count: 2_048),
                      String(repeating: "-eyJaaaaaaaa.bbbbbbbb", count: 1_200),
                      String(repeating: "eyJ.", count: 6_144)]
        for shape in shapes {
            let start = Date()
            _ = Redactor.redact(shape)
            let ms = Date().timeIntervalSince(start) * 1000
            print("jwt-shape \(shape.prefix(12))… \(shape.utf16.count) units: \(String(format: "%.1f", ms)) ms")
            #expect(ms < 250)
        }
    }
}

