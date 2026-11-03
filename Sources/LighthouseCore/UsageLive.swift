import Foundation

/// Reads the Claude Code OAuth token from the Keychain item `Claude Code-credentials` (SPEC §4)
/// through Apple's `/usr/bin/security`, the same tool Claude Code uses to write and read the item.
///
/// Why not `SecItemCopyMatching`: macOS ties a Keychain "Always Allow" to the reading app's code
/// signature. Lighthouse is signed ad hoc, so every update has a new signature and the owner was
/// asked again after each one. Claude Code creates and updates the item with `security
/// add-generic-password -U`, so the item's access list already trusts `/usr/bin/security`, whose
/// signature never changes: reading through it shows no prompt, across Lighthouse updates and
/// Claude Code's token refreshes. If the item's access list does not trust it (an item made some
/// other way), macOS still asks once, for `security`, and that answer lasts.
///
/// The secret arrives on the child's standard output into memory only; it is never in argv, never
/// written anywhere and never logged (V-SECRETS).
public struct ClaudeKeychainCredentials: UsageCredentialSource {
    public static let service = "Claude Code-credentials"
    static let tool = "/usr/bin/security"
    /// A read waiting on a Keychain dialog is given up after this long (counted as denied).
    static let timeout: TimeInterval = 120
    let claudeJSON: String
    let access: SourceAccess

    public init(claudeJSON: String = NSHomeDirectory() + "/.claude.json", access: SourceAccess = ReadOnlyFileSystem()) {
        self.claudeJSON = claudeJSON
        self.access = access
    }

    public var location: String { "Keychain · \(Self.service)" }
    public var mayPrompt: Bool { true }

    public func currentAccountId() -> String? { ClaudeCredentialParser.accountId(claudeJSON: claudeJSON, access: access) }

    public func load() -> CredentialResult {
        let (status, output) = Self.run(arguments: ["find-generic-password", "-s", Self.service, "-w"])
        switch status {
        case 0:
            guard let data = Self.secretData(output) else { return .unreadable }
            return ClaudeCredentialParser.parse(data, accountId: ClaudeCredentialParser.accountId(claudeJSON: claudeJSON, access: access))
        case 44: // errSecItemNotFound
            return .missing
        case 36, 51, 128, -1: // interaction not allowed, user canceled, auth failed, timed out
            return .denied
        default:
            return .unreadable
        }
    }

    /// `security -w` prints the secret and a newline; a secret that is not printable text comes as hex.
    static func secretData(_ output: Data) -> Data? {
        var data = output
        while let last = data.last, last == 0x0A || last == 0x0D { data.removeLast() }
        guard !data.isEmpty else { return nil }
        if data.first == UInt8(ascii: "{") { return data }
        let hex = String(decoding: data, as: UTF8.self)
        guard hex.count.isMultiple(of: 2), hex.allSatisfy(\.isHexDigit) else { return data }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return data }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    /// Runs the tool with an empty environment through the app's one process-launch path
    /// (`SystemProcessLauncher`); returns its exit status (-1 on timeout or launch failure) and
    /// standard output. Standard error is only counted.
    static func run(arguments: [String]) -> (Int32, Data) {
        let command = SummaryCommand(executable: tool, arguments: arguments, environment: [:], directory: "/")
        let outcome = SystemProcessLauncher.runBlocking(command, input: Data(), timeout: timeout)
        guard outcome.launched, !outcome.timedOut, let code = outcome.exitCode else { return (-1, Data()) }
        return (code, outcome.stdout)
    }
}

/// HTTPS transport for the two usage endpoints. Ephemeral session: no cookies, no URL cache, no
/// credential storage on disk. Redirects are refused, so a token is never sent to another host.
/// Any URL outside `UsageEndpoints.allowed` fails before a connection is made (V-NET).
public final class HTTPSUsageTransport: NSObject, UsageTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession

    public override init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        super.init()
    }

    public func get(_ request: UsageRequest) async throws(UsageTransportError) -> UsageHTTPResponse {
        guard UsageEndpoints.isAllowed(request.url) else { throw .blocked }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        urlRequest.httpMethod = "GET"
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest, delegate: self)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
                throw .offline
            default: throw .failed
            }
        } catch {
            throw .failed
        }
        guard let http = response as? HTTPURLResponse, http.url.map(UsageEndpoints.isAllowed) ?? false else { throw .blocked }
        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        return UsageHTTPResponse(status: http.statusCode, body: data, retryAfter: retryAfter)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

extension UsageMonitor {
    /// The production monitor: Claude from the Keychain, Codex from `~/.codex/auth.json`. Nothing is
    /// read until the app polls a provider the owner enabled.
    public static func live() -> UsageMonitor {
        UsageMonitor(providers: [
            .claude: Provisioned(adapter: ClaudeUsageAdapter(), credentials: ClaudeKeychainCredentials()),
            .codex: Provisioned(adapter: CodexUsageAdapter(), credentials: CodexAuthFile()),
        ], transport: HTTPSUsageTransport())
    }
}
