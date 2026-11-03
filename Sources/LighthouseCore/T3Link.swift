import CryptoKit
import Foundation

/// The one place Lighthouse sends anything to an agent (SPEC 2.11): nudges into stalled T3 Code
/// threads through T3's own MCP server on this Mac. Off unless the owner turns nudges on.
///
/// Connecting follows T3's OAuth flow for MCP clients: register, approve with a one-time pairing code
/// from T3's own `t3 auth pairing create` (the code T3's "Connect agent" page asks for), and exchange
/// the code for a token. T3 issues no refresh tokens, so Lighthouse connects again before the token
/// expires. Lighthouse asks for Full access: T3 refuses a message to a thread whose access is above
/// the token's, and new T3 threads start on Full access.
///
/// The token is kept in one file, mode 0600, in a mode 0700 folder in Lighthouse's Application
/// Support folder. It is never stored in the SQLite store, logged, or put in the Keychain (an ad-hoc
/// signed app's Keychain items prompt again after every update). Each token is one T3 session;
/// Lighthouse revokes only that session when it reconnects or disconnects.
///
/// Every request goes to the T3 server on 127.0.0.1; nothing else is contacted and nothing listens.
public actor T3Link {
    public static let base = "http://127.0.0.1:3773"
    /// Sent as data only: T3 answers the approval with a redirect to it, which Lighthouse reads
    /// without following. Nothing listens there.
    static let redirectURI = "http://127.0.0.1:51829/t3-callback"
    static let clientName = "Lighthouse 2"
    static let access = "full-access"
    static let scopes = ["orchestration:read", "orchestration:operate", "settings:write", "source-control:write"]
    /// Connect again when the token has less than this left.
    static let renewBefore: TimeInterval = 3 * 86400
    static let protocolVersion = "2025-06-18"

    public enum Failure: Error, Equatable, Sendable {
        case noCLI
        case cli(String)
        case unreachable
        case refused(String)
        case grant(String)
        case badAnswer(String)

        public var message: String {
            switch self {
            case .noCLI: "T3 Code's t3 command was not found (~/.t3/bin/t3)."
            case .cli(let why): "t3 auth pairing create failed: \(why). Is T3 Code running?"
            case .unreachable: "T3 Code is not answering on 127.0.0.1:3773. Is it running?"
            case .refused(let why): "T3 Code refused: \(why)"
            case .grant(let why): why
            case .badAnswer(let why): "T3 Code answered unexpectedly: \(why)"
            }
        }
    }

    public struct Token: Sendable, Equatable, Codable {
        public var accessToken: String
        public var expiresAt: Date
        public var sessionId: String?
        public var access: String
    }

    /// What Settings shows. Never the token.
    public struct Status: Sendable, Equatable {
        public var connected: Bool
        public var access: String?
        public var expiresAt: Date?
        public var lastError: String?

        public init(connected: Bool, access: String? = nil, expiresAt: Date? = nil, lastError: String? = nil) {
            self.connected = connected
            self.access = access
            self.expiresAt = expiresAt
            self.lastError = lastError
        }
    }

    public enum SendResult: Sendable, Equatable {
        case sent
        case failed(String)
    }

    private let transport: T3Transport
    private let launcher: SummaryProcessLauncher
    private let folder: URL
    private let home: String
    private var lastError: String?

    public init(folder: URL = T3Link.defaultFolder, home: String = NSHomeDirectory(),
                transport: T3Transport = LoopbackTransport(), launcher: SummaryProcessLauncher = SystemProcessLauncher()) {
        self.folder = folder
        self.home = home
        self.transport = transport
        self.launcher = launcher
    }

    public static var defaultFolder: URL { Store.defaultURL.deletingLastPathComponent().appendingPathComponent("t3", isDirectory: true) }
    var tokenFile: URL { folder.appendingPathComponent("token.json") }

    /// T3 thread and session ids: `thread:…`, `mcp:…` with percent-escapes (v1's tested pattern).
    public static func validThreadId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 300 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":%._-".contains($0)) }
    }

    public func status(now: Date = Date()) -> Status {
        let token = loadToken()
        return Status(connected: token.map { $0.expiresAt > now } ?? false, access: token?.access, expiresAt: token?.expiresAt, lastError: lastError)
    }

    // MARK: Sending

    /// Sends one message into a T3 thread. T3's `auto` mode starts a turn on an idle thread and steers
    /// a running one. `requestId` makes a repeat of the same nudge one message in T3.
    public func send(threadId: String, message: String, requestId: String, now: Date = Date()) async -> SendResult {
        guard Self.validThreadId(threadId) else { return .failed("bad thread id") }
        do {
            let token = try await usableToken(now: now)
            var session: String?
            let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                             "params": ["protocolVersion": Self.protocolVersion, "capabilities": [:] as [String: Any],
                                                        "clientInfo": ["name": Self.clientName, "version": "1"]]]
            let first = try await mcp(initialize, token: token, session: nil)
            session = first.session
            guard first.json?["error"] == nil else { throw Failure.refused("initialize") }
            _ = try await mcp(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:] as [String: Any]], token: token, session: session)
            let call: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                       "params": ["name": "t3_thread_send",
                                                  "arguments": ["threadId": threadId, "message": message, "mode": "auto", "clientRequestId": requestId]]]
            let answer = try await mcp(call, token: token, session: session)
            if let error = answer.json?["error"] as? [String: Any] { throw Failure.refused(String(describing: error["message"] ?? "error")) }
            let result = answer.json?["result"] as? [String: Any]
            if result?["isError"] as? Bool == true { throw Failure.refused(Self.text(of: result) ?? "t3_thread_send failed") }
            guard result != nil else { throw Failure.badAnswer("no result") }
            lastError = nil
            return .sent
        } catch let failure as Failure {
            lastError = failure.message
            return .failed(failure.message)
        } catch {
            lastError = Failure.unreachable.message
            return .failed(Failure.unreachable.message)
        }
    }

    private static func text(of result: [String: Any]?) -> String? {
        let parts = (result?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return parts.isEmpty ? nil : String(parts.joined(separator: " ").prefix(200))
    }

    private func mcp(_ body: [String: Any], token: Token, session: String?) async throws -> (json: [String: Any]?, session: String?) {
        var headers = ["Authorization": "Bearer " + token.accessToken, "Content-Type": "application/json",
                       "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": Self.protocolVersion]
        if let session { headers["Mcp-Session-Id"] = session }
        let response = try await transport.send(T3HTTPRequest(method: "POST", path: "/mcp", headers: headers,
                                                              body: try JSONSerialization.data(withJSONObject: body)))
        if response.status == 401 || response.status == 403 { throw Failure.refused("not authorized (\(response.status))") }
        guard (200..<300).contains(response.status) else { throw Failure.refused("HTTP \(response.status)") }
        return (Self.jsonRPC(response), response.headers["mcp-session-id"] ?? session)
    }

    /// The JSON-RPC message in a plain JSON or event-stream answer.
    static func jsonRPC(_ response: T3HTTPResponse) -> [String: Any]? {
        let text = String(decoding: response.body, as: UTF8.self)
        let lines = (response.headers["content-type"] ?? "").contains("text/event-stream")
            ? text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) }
            : [text]
        for line in lines {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return object }
        }
        return nil
    }

    // MARK: Connecting

    /// The saved token, connecting first when there is none or it expires within `renewBefore`.
    func usableToken(now: Date) async throws -> Token {
        if let token = loadToken(), token.expiresAt.timeIntervalSince(now) > Self.renewBefore { return token }
        return try await connect(now: now)
    }

    /// Runs T3's OAuth flow with a fresh pairing code and saves the token. Any earlier session this
    /// install held is revoked afterwards.
    @discardableResult
    public func connect(now: Date = Date()) async throws -> Token {
        do {
            let token = try await authorize(now: now)
            let previous = loadToken()?.sessionId
            try save(token)
            if let previous, previous != token.sessionId { await revoke(previous) }
            lastError = nil
            return token
        } catch let failure as Failure {
            lastError = failure.message
            throw failure
        }
    }

    /// Deletes the token and revokes its T3 session.
    public func disconnect() async {
        let session = loadToken()?.sessionId
        try? FileManager.default.removeItem(at: tokenFile)
        if let session { await revoke(session) }
        lastError = nil
    }

    private func authorize(now: Date) async throws -> Token {
        let code = try await pairingCode()
        let metadata = try await getJSON("/.well-known/oauth-authorization-server")
        guard let register = Self.localPath(metadata["registration_endpoint"]), let tokenPath = Self.localPath(metadata["token_endpoint"]) else {
            throw Failure.badAnswer("no registration or token endpoint")
        }
        let client = try await postJSON(register, ["client_name": Self.clientName, "redirect_uris": [Self.redirectURI],
                                                   "grant_types": ["authorization_code"], "response_types": ["code"],
                                                   "token_endpoint_auth_method": "none"])
        guard let clientId = client["client_id"] as? String, !clientId.isEmpty else { throw Failure.badAnswer("no client id") }
        let verifier = Self.randomURLSafe(48)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)
        let resource = Self.base + "/mcp"
        let request: [String: String] = ["response_type": "code", "client_id": clientId, "redirect_uri": Self.redirectURI,
                                         "code_challenge": challenge, "code_challenge_method": "S256", "state": state, "resource": resource]
        // The call T3's own Connect agent page makes when the owner approves with a pairing code.
        let decision = try await postJSON("/oauth/mcp/decision", ["authorization": request,
                                                                  "decision": ["_tag": "pairing-code", "access": Self.access, "code": code]])
        guard let redirect = (decision["redirectTo"] as? String).flatMap(URLComponents.init(string:)) else { throw Failure.badAnswer("no redirect") }
        let query = Dictionary((redirect.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["state"] == state else { throw Failure.badAnswer("state did not match") }
        guard let authCode = query["code"], !authCode.isEmpty else { throw Failure.refused(query["error_description"] ?? query["error"] ?? "no code") }
        let answer = try await postForm(tokenPath, ["grant_type": "authorization_code", "code": authCode, "redirect_uri": Self.redirectURI,
                                                    "client_id": clientId, "code_verifier": verifier, "resource": resource])
        guard let accessToken = answer["access_token"] as? String, !accessToken.isEmpty else { throw Failure.badAnswer("no access token") }
        let claims = Self.claims(accessToken)
        let granted = Self.grantedAccess(claims: claims, scope: answer["scope"] as? String)
        let session = claims["sid"] as? String
        guard granted == Self.access else {
            if let session { await revoke(session) }
            throw Failure.grant("T3 granted \(granted ?? "unknown") access, not Full access, so it would refuse nudges to Full access threads.")
        }
        let seconds = (answer["expires_in"] as? Double) ?? (answer["expires_in"] as? Int).map(Double.init) ?? 0
        guard seconds > 0 else { throw Failure.badAnswer("no expiry") }
        return Token(accessToken: accessToken, expiresAt: now.addingTimeInterval(seconds), sessionId: session, access: granted ?? Self.access)
    }

    /// A one-time pairing code from T3's own command, limited to the scopes Full access needs.
    private func pairingCode() async throws -> String {
        guard let cli = cliPath() else { throw Failure.noCLI }
        var arguments = ["auth", "pairing", "create", "--ttl", "5m", "--label", Self.clientName, "--json"]
        for scope in Self.scopes { arguments += ["--scope", scope] }
        let outcome = await launcher.run(SummaryCommand(executable: cli, arguments: arguments, environment: ["HOME": home], directory: "/"),
                                         input: Data(), timeout: 60)
        guard outcome.launched, outcome.exitCode == 0 else { throw Failure.cli("exit \(outcome.exitCode.map(String.init) ?? "none")") }
        guard let object = try? JSONSerialization.jsonObject(with: outcome.stdout) as? [String: Any],
              let code = object["credential"] as? String, !code.isEmpty else { throw Failure.cli("no pairing code") }
        return code
    }

    private func revoke(_ session: String) async {
        guard let cli = cliPath(), Self.validThreadId(session) else { return }
        _ = await launcher.run(SummaryCommand(executable: cli, arguments: ["auth", "session", "revoke", session], environment: ["HOME": home], directory: "/"),
                               input: Data(), timeout: 60)
    }

    func cliPath() -> String? {
        let candidate = (home as NSString).appendingPathComponent(".t3/bin/t3")
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Only paths on the T3 server itself are used from T3's metadata.
    static func localPath(_ value: Any?) -> String? {
        guard let string = value as? String, string.hasPrefix(base + "/") else { return nil }
        return String(string.dropFirst(base.count))
    }

    /// The access level T3 gave the token, worked out as T3's server does: without
    /// `orchestration:operate` it is read only; otherwise its ceiling is the `rtc` claim, or
    /// "approval-required" when there is none.
    static func grantedAccess(claims: [String: Any], scope: String?) -> String? {
        let scopes = (claims["scopes"] as? [String]) ?? scope?.split(separator: " ").map(String.init)
        guard let scopes, !scopes.isEmpty else { return nil }
        guard scopes.contains("orchestration:operate") else { return "read-only" }
        return (claims["rtc"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "approval-required"
    }

    /// A T3 token is `base64url(claims).signature`.
    static func claims(_ token: String) -> [String: Any] {
        guard let part = token.split(separator: ".").first else { return [:] }
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func getJSON(_ path: String) async throws -> [String: Any] {
        try Self.object(try await transport.send(T3HTTPRequest(method: "GET", path: path, headers: ["Accept": "application/json"], body: nil)))
    }

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try Self.object(try await transport.send(T3HTTPRequest(method: "POST", path: path,
                                                               headers: ["Content-Type": "application/json", "Accept": "application/json"],
                                                               body: try JSONSerialization.data(withJSONObject: body))))
    }

    private func postForm(_ path: String, _ fields: [String: String]) async throws -> [String: Any] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        return try Self.object(try await transport.send(T3HTTPRequest(method: "POST", path: path,
                                                                      headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                                                                      body: Data(body.utf8))))
    }

    private static func object(_ response: T3HTTPResponse) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]) ?? [:]
        guard (200..<300).contains(response.status) else {
            let why = (object["message"] ?? object["error_description"] ?? object["error"]).map { String(describing: $0) } ?? "HTTP \(response.status)"
            throw Failure.refused(String(why.prefix(200)))
        }
        return object
    }

    // MARK: Token file

    func loadToken() -> Token? {
        guard let data = try? Data(contentsOf: tokenFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Token.self, from: data)
    }

    /// Writes the token in a 0700 folder, then sets the file to 0600.
    private func save(_ token: Token) throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(token).write(to: tokenFile, options: [.atomic])
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        } catch {
            throw Failure.badAnswer("could not save the T3 token")
        }
    }
}

public struct T3HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data?
}

public struct T3HTTPResponse: Sendable {
    public var status: Int
    /// Lower-cased header names.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol T3Transport: Sendable {
    func send(_ request: T3HTTPRequest) async throws -> T3HTTPResponse
}

/// HTTP to the T3 server on 127.0.0.1 only: no cookies, no cache, no redirects followed.
public struct LoopbackTransport: T3Transport {
    public init() {}

    public func send(_ request: T3HTTPRequest) async throws -> T3HTTPResponse {
        guard request.path.hasPrefix("/"), let url = URL(string: T3Link.base + request.path), url.host == "127.0.0.1", url.port == 3773 else {
            throw T3Link.Failure.badAnswer("refused a request outside the T3 server")
        }
        var urlRequest = URLRequest(url: url, timeoutInterval: 15)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw T3Link.Failure.unreachable }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields { headers[String(describing: name).lowercased()] = String(describing: value) }
        return T3HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
