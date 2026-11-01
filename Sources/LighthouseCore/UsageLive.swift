import Foundation
import Security

/// Reads the Claude Code OAuth token from the Keychain item `Claude Code-credentials` (SPEC §4).
/// The first read shows the system Keychain prompt; the user's "Always Allow" covers later reads.
/// The token stays in memory; it is never written anywhere (V-SECRETS).
public struct ClaudeKeychainCredentials: UsageCredentialSource {
    public static let service = "Claude Code-credentials"
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return .unreadable }
            return ClaudeCredentialParser.parse(data, accountId: ClaudeCredentialParser.accountId(claudeJSON: claudeJSON, access: access))
        case errSecItemNotFound:
            return .missing
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .denied
        default:
            return .unreadable
        }
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
